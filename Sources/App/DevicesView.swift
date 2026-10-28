import SwiftUI
import CoreBluetooth
import Combine
import CryptoKit

struct BLEPeer: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
}
struct BLEStream: Identifiable, Sendable {
    let id: String
    let service: String
    let characteristic: String
    var selected = false
    var subscribed = false
}
struct BLECaptureResult: Sendable {
    let sessionID: UUID
    let folder: URL
    let files: [URL]
    let profile: ExternalDeviceProfile
}
private struct BLEPacket: Codable {
    let sequence: UInt64
    let received_utc_epoch_s: Double
    let received_system_uptime_s: Double
    let stream: String
    let service: String
    let characteristic: String
    let payload_bytes: Int
    let payload_base64: String
}

/// Opaque notification payloads, bounded memory, serial disk writes.
private final class BLEFileWriter: @unchecked Sendable {
    static func inboxURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("BLEInbox", isDirectory: true)
    }
    let folder: URL
    let files: [URL]
    private let queue = DispatchQueue(label: "scope.ble.disk", qos: .utility)
    private let lock = NSLock()
    private let handle: FileHandle
    private var pending = 0
    private var closing = false
    private var failure: String?
    private var bytes: Int64 = 0
    private var packets: UInt64 = 0
    private var digest = SHA256()
    private var lastSync = Date()
    private var nextSpaceCheck: Int64 = 0
    private var metadata: [String: String]

    init(profile: ExternalDeviceProfile, streams: [BLEStream], identity: [String: String]) throws {
        var inbox = try Self.inboxURL()
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try inbox.setResourceValues(values)
        folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: folder.path)
        files = [folder.appendingPathComponent("packets.jsonl"),
                 folder.appendingPathComponent("capture.json"),
                 folder.appendingPathComponent("device.json")]
        metadata = identity
        metadata["state"] = "open_or_interrupted"
        metadata["startedAt"] = ISO8601DateFormatter().string(from: Date())
        metadata["transport"] = "Bluetooth LE GATT notifications or indications"
        metadata["format"] = "JSON Lines; payload_base64 preserves each received payload exactly."
        metadata["timing"] = "Phone arrival epoch and monotonic uptime, not sensor acquisition time."
        metadata["completeness"] = "Device-level loss detection needs firmware sequence/checksum support."
        metadata["streams"] = streams.filter(\.selected).map(\.id).joined(separator: ",")
        try JSONEncoder().encode(profile).write(to: files[2], options: .atomic)
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: files[1], options: .atomic)
        try Data().write(to: files[0], options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: files[0])
    }
    func append(_ data: Data, stream: BLEStream, epoch: Double, uptime: Double) -> Bool {
        let reservation = data.count * 2 + 2048
        lock.lock()
        guard !closing, failure == nil else { lock.unlock(); return false }
        guard reservation <= 4 * 1024 * 1024 - pending else {
            failure = "Disk queue limit reached. Some received data was not saved."
            lock.unlock(); return false
        }
        pending += reservation; lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); pending -= reservation; lock.unlock() }
            lock.lock(); let failed = failure != nil; lock.unlock()
            guard !failed else { return }
            do {
                if bytes >= nextSpaceCheck {
                    let attributes = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
                    guard let free = attributes[.systemFreeSize] as? NSNumber,
                          free.int64Value > LocalStore.minimumFreeBytes else {
                        throw RecorderError(message: "Bluetooth recording stopped at the storage reserve.")
                    }
                    nextSpaceCheck = bytes + 1024 * 1024
                }
                let packet = BLEPacket(sequence: packets + 1, received_utc_epoch_s: epoch,
                    received_system_uptime_s: uptime, stream: stream.id, service: stream.service,
                    characteristic: stream.characteristic, payload_bytes: data.count,
                    payload_base64: data.base64EncodedString())
                var line = try JSONEncoder().encode(packet); line.append(10)
                try handle.write(contentsOf: line)
                digest.update(data: line); bytes += Int64(line.count); packets += 1
                if Date().timeIntervalSince(lastSync) >= 1 {
                    try handle.synchronize(); lastSync = Date()
                }
            } catch { lock.lock(); failure = error.localizedDescription; lock.unlock() }
        }
        return true
    }
    func finish(reason: String?) async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock(); closing = true; lock.unlock()
            queue.async { [self] in
                lock.lock(); var issue = failure ?? reason; lock.unlock()
                do { try handle.synchronize(); try handle.close() }
                catch { issue = issue ?? error.localizedDescription }
                do {
                    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
                    let actual = try SessionFiles.fingerprint(files[0])
                    if actual.0 != bytes || actual.1 != hash { issue = issue ?? "Post-write verification failed." }
                    if packets == 0 { issue = issue ?? "No BLE payloads arrived during this capture." }
                    metadata["state"] = issue == nil ? "closed_received_bytes_verified" : "incomplete"
                    metadata["issue"] = issue ?? ""
                    metadata["endedAt"] = ISO8601DateFormatter().string(from: Date())
                    metadata["packetFileBytes"] = String(bytes)
                    metadata["receivedPacketsSaved"] = String(packets)
                    metadata["packetFileSHA256"] = hash
                    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                        .write(to: files[1], options: .atomic)
                } catch { issue = issue ?? error.localizedDescription }
                continuation.resume(returning: issue)
            }
        }
    }
}

@MainActor
final class BLERecorder: NSObject, ObservableObject,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var peers: [BLEPeer] = []
    @Published private(set) var streams: [BLEStream] = []
    @Published private(set) var status = "Bluetooth not started"
    @Published private(set) var scanning = false
    @Published private(set) var connecting = false
    @Published private(set) var discovering = false
    @Published private(set) var connectedID: UUID?
    @Published private(set) var deviceName = "No device connected"
    @Published private(set) var manufacturer = ""
    @Published private(set) var modelNumber = ""
    @Published private(set) var serialNumber = ""
    @Published private(set) var capturing = false
    @Published private(set) var finalizing = false
    @Published private(set) var preparing = false
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var receivedPackets: Int64 = 0
    @Published private(set) var lastReceived: Date?
    @Published var includeInSessions = false
    @Published var issue: String?
    private var central: CBCentralManager?
    private var known: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var serviceIDs: [ObjectIdentifier: String] = [:]
    private var pendingServices = 0
    private var scanRequested = false
    private var timeout: Task<Void, Never>?
    private var scanTimeout: Task<Void, Never>?
    private var prepared: BLEFileWriter?
    private var writer: BLEFileWriter?
    private var preparedProfile: ExternalDeviceProfile?
    private var linkedID: UUID?
    private var closeTask: Task<Void, Never>?
    private var finished: BLECaptureResult?
    private var packetCount: Int64 = 0
    private var byteCount: Int64 = 0
    private var lastPublication = Date.distantPast
    private var aliases: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "scope.ble.aliases") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "scope.ble.aliases") }
    }
    var ready: Bool {
        let selected = streams.filter(\.selected)
        return central?.state == .poweredOn && peripheral?.state == .connected &&
            !discovering && !selected.isEmpty && selected.allSatisfy(\.subscribed)
    }
    var configurationLocked: Bool { capturing || preparing || finalizing || prepared != nil || linkedID != nil }
    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(120))
    }
    private func name(_ p: CBPeripheral, advertised: String? = nil) -> String {
        clean(aliases[p.identifier.uuidString]) ?? clean(advertised) ?? clean(p.name) ?? "Unnamed sensor"
    }
    func renameDevice(_ text: String) {
        guard !configurationLocked, let peripheral, let text = clean(text) else { return }
        var saved = aliases; saved[peripheral.identifier.uuidString] = text; aliases = saved
        deviceName = text
        if let index = peers.firstIndex(where: { $0.id == peripheral.identifier }) { peers[index].name = text }
    }
    func scan() {
        guard !configurationLocked, peripheral == nil else { return }
        issue = nil; scanRequested = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else if central?.state == .poweredOn { startScan() }
        else { status = "Bluetooth unavailable — check iOS Settings" }
    }
    private func startScan() {
        scanRequested = false; scanning = true; peers = []; known = [:]
        status = "Looking for nearby sensors"
        central?.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.stopScan()
        }
    }
    func stopScan() {
        scanRequested = false; central?.stopScan(); scanning = false; scanTimeout?.cancel()
        if peripheral == nil { status = peers.isEmpty ? "No sensors found" : "Choose a sensor" }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            status = "Bluetooth ready"
            if scanRequested { startScan() }
        } else {
            if writer != nil { stop(reason: "Bluetooth became unavailable.") }
            scanning = false; connecting = false; discovering = false; connectedID = nil
            peripheral = nil; streams = []; characteristics = [:]
            switch central.state {
            case .unauthorized: status = "Allow Bluetooth in iOS Settings"
            case .poweredOff: status = "Turn on Bluetooth in iOS Settings"
            case .unsupported: status = "Bluetooth LE is unavailable"
            default: status = "Bluetooth is initializing"
            }
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        known[peripheral.identifier] = peripheral
        let peer = BLEPeer(id: peripheral.identifier,
            name: name(peripheral, advertised: advertisementData[CBAdvertisementDataLocalNameKey] as? String),
            rssi: RSSI.intValue)
        if let index = peers.firstIndex(where: { $0.id == peer.id }) { peers[index] = peer }
        else { peers.append(peer) }
        peers.sort { $0.rssi > $1.rssi }
    }
    func connect(_ peer: BLEPeer) {
        guard !configurationLocked, peripheral == nil, let p = known[peer.id] else { return }
        stopScan(); issue = nil; peripheral = p; p.delegate = self
        deviceName = peer.name; manufacturer = ""; modelNumber = ""; serialNumber = ""
        streams = []; characteristics = [:]; serviceIDs = [:]
        connecting = true; status = "Connecting to \(deviceName)"
        central?.connect(p, options: nil)
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            self?.disconnect(reason: "Connection or service discovery timed out. Try again.")
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        connectedID = peripheral.identifier; connecting = false; discovering = true
        status = "Finding data streams"; peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        timeout?.cancel(); self.peripheral = nil; connecting = false; connectedID = nil
        issue = error?.localizedDescription ?? "Could not connect. Keep the device nearby and try again."
        status = "Not connected"
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        stop(reason: error?.localizedDescription ?? "Bluetooth link disconnected; review capture completeness.")
        self.peripheral = nil; connectedID = nil; connecting = false; discovering = false
        streams = []; characteristics = [:]; timeout?.cancel(); status = "Disconnected"
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error { disconnect(reason: error.localizedDescription); return }
        let services = peripheral.services ?? []; pendingServices = services.count
        if services.isEmpty { discovering = false; timeout?.cancel(); status = "No GATT services available" }
        for (index, service) in services.enumerated() {
            serviceIDs[ObjectIdentifier(service)] = "\(service.uuid.uuidString):\(index)"
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error { disconnect(reason: error.localizedDescription); return }
        for (index, c) in (service.characteristics ?? []).enumerated() {
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                let key = "\(serviceIDs[ObjectIdentifier(service)] ?? service.uuid.uuidString)/\(c.uuid.uuidString):\(index)"
                characteristics[key] = c
                streams.append(BLEStream(id: key, service: service.uuid.uuidString, characteristic: c.uuid.uuidString))
            }
            if ["180A", "1800"].contains(service.uuid.uuidString),
               ["2A29", "2A24", "2A25", "2A00"].contains(c.uuid.uuidString), c.properties.contains(.read) {
                peripheral.readValue(for: c)
            }
        }
        pendingServices -= 1
        if pendingServices == 0 {
            discovering = false; timeout?.cancel()
            status = streams.isEmpty ? "No notification streams available" : "Connected · choose streams"
        }
    }
    func setStream(_ id: String, enabled: Bool) {
        guard !configurationLocked, let p = peripheral, let c = characteristics[id],
              let index = streams.firstIndex(where: { $0.id == id }) else { return }
        streams[index].selected = enabled; issue = nil; p.setNotifyValue(enabled, for: c)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral,
              let key = characteristics.first(where: { $0.value === characteristic })?.key,
              let index = streams.firstIndex(where: { $0.id == key }) else { return }
        streams[index].subscribed = characteristic.isNotifying
        if let error { issue = "Stream subscription failed: \(error.localizedDescription)" }
        if capturing && streams[index].selected && (!characteristic.isNotifying || error != nil) {
            stop(reason: "A selected stream stopped notifying.")
        }
        if !capturing { status = ready ? "Ready to record" : "Connected · choose streams" }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        let stream = characteristics.first(where: { $0.value === characteristic })
            .flatMap { entry in streams.first(where: { $0.id == entry.key && $0.selected }) }
        if let error {
            if stream != nil { stop(reason: "BLE receive error: \(error.localizedDescription)") }
            return
        }
        guard let data = characteristic.value else { return }
        if let service = characteristic.service, ["180A", "1800"].contains(service.uuid.uuidString),
           let text = clean(String(data: data, encoding: .utf8)) {
            switch characteristic.uuid.uuidString {
            case "2A29": manufacturer = text
            case "2A24": modelNumber = text
            case "2A25": serialNumber = text
            case "2A00": if clean(aliases[peripheral.identifier.uuidString]) == nil { deviceName = text }
            default: break
            }
        }
        guard capturing, let writer, let stream else { return }
        let now = Date()
        guard writer.append(data, stream: stream, epoch: now.timeIntervalSince1970,
                            uptime: ProcessInfo.processInfo.systemUptime) else {
            stop(reason: "BLE disk recording failed or could not keep up. Review the partial capture."); return
        }
        byteCount += Int64(data.count); packetCount += 1
        if now.timeIntervalSince(lastPublication) >= 0.25 {
            receivedBytes = byteCount; receivedPackets = packetCount
            lastReceived = now; lastPublication = now; status = "Receiving data"
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === self.peripheral else { return }
        disconnect(reason: "Device services changed. Reconnect and select streams again.")
    }
    func prepareLinkedCapture() async throws {
        guard includeInSessions else { return }
        guard ready, !configurationLocked, let id = connectedID else {
            throw RecorderError(message: "Open Devices, connect your BLE sensor and enable its data streams, or turn off Record with sessions.")
        }
        preparing = true; defer { preparing = false }
        let profile = ExternalDeviceProfile(id: id, name: deviceName, manufacturer: manufacturer,
            model: modelNumber, notes: "BLE; device serial: \(serialNumber)")
        let selectedStreams = streams
        let identity = ["peripheralIdentifier": id.uuidString, "displayName": deviceName,
            "reportedName": peripheral?.name ?? "", "serialNumber": serialNumber]
        let newWriter = try await Task.detached(priority: .utility) {
            try BLEFileWriter(profile: profile, streams: selectedStreams, identity: identity)
        }.value
        guard ready, connectedID == id else {
            _ = await newWriter.finish(reason: "Link changed before phone recording started.")
            throw RecorderError(message: "The BLE connection changed. Reconnect and try again.")
        }
        prepared = newWriter; preparedProfile = profile; issue = nil
    }
    func beginLinkedCapture(sessionID: UUID) {
        guard let prepared else { return }
        writer = prepared; self.prepared = nil; linkedID = sessionID; finished = nil
        byteCount = 0; packetCount = 0; receivedBytes = 0; receivedPackets = 0
        lastReceived = nil; lastPublication = .distantPast
        capturing = true; status = "Recording · waiting for data"
        if !ready { stop(reason: "BLE connection changed while the phone session was starting.") }
    }
    func discardPreparedCapture() {
        guard let prepared else { return }; self.prepared = nil
        Task { _ = await prepared.finish(reason: "Phone session did not start.") }
    }
    func stop(reason: String? = nil) {
        if let reason { issue = reason }
        guard let current = writer, let sessionID = linkedID, let profile = preparedProfile else { return }
        writer = nil; capturing = false; finalizing = true
        receivedBytes = byteCount; receivedPackets = packetCount; status = "Saving Bluetooth data"
        closeTask = Task { [weak self] in
            let error = await current.finish(reason: reason)
            guard let self else { return }
            finished = BLECaptureResult(sessionID: sessionID, folder: current.folder,
                files: current.files, profile: profile)
            finalizing = false; issue = error
            status = error == nil ? "Bluetooth data saved" : "Partial Bluetooth data saved"
        }
    }
    func finishLinkedCapture(sessionID: UUID, reason: String? = nil) async -> BLECaptureResult? {
        guard linkedID == sessionID else { return nil }
        stop(reason: reason); await closeTask?.value
        let result = finished; finished = nil; linkedID = nil; closeTask = nil
        return result
    }
    func disconnect(reason: String? = nil) {
        stop(reason: reason); timeout?.cancel()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral?.delegate = nil; peripheral = nil; connectedID = nil
        connecting = false; discovering = false; streams = []; characteristics = [:]
        status = "Not connected"
        if let reason { issue = reason }
    }
}

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ble: BLERecorder
    @State private var rename = false
    @State private var label = ""
    @State private var recoveryFolders: [URL] = []
    @State private var savingRecovery = false
    @State private var recoveryMessage: String?

    var body: some View {
        List {
            Section {
                Label(ble.deviceName, systemImage: "sensor.fill")
                    .font(.headline).padding(.vertical, 4)
                LabeledContent("Status", value: ble.status)
                if ble.connectedID != nil {
                    Button("Rename device") { label = ble.deviceName; rename = true }
                        .disabled(ble.configurationLocked || model.active != nil)
                }
                if let issue = ble.issue { Text(issue).font(.footnote).foregroundStyle(.orange) }
            }
            if ble.connectedID == nil {
                Section("Nearby sensors") {
                    Button(ble.scanning ? "Stop scanning" : "Find Bluetooth sensors") {
                        if ble.scanning { ble.stopScan() } else { ble.scan() }
                    }.disabled(ble.connecting || ble.configurationLocked || model.active != nil)
                    ForEach(ble.peers) { peer in
                        Button { ble.connect(peer) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(peer.name).foregroundStyle(.primary)
                                    Text("Signal \(peer.rssi) dBm · ID \(peer.id.uuidString.prefix(8))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption)
                            }
                        }.disabled(ble.connecting || ble.configurationLocked || model.active != nil)
                    }
                    if ble.connecting { Button("Cancel connection") { ble.disconnect() } }
                }
            } else {
                Section {
                    if ble.discovering { ProgressView("Finding data streams…") }
                    ForEach(ble.streams) { stream in
                        Toggle(isOn: Binding(get: {
                            ble.streams.first(where: { $0.id == stream.id })?.selected ?? false
                        }, set: { ble.setStream(stream.id, enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stream.characteristic).font(.subheadline).textSelection(.enabled)
                                Text(stream.subscribed ? "Subscribed" : "Service \(stream.service)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(ble.configurationLocked || ble.discovering || model.active != nil)
                    }
                    if !ble.discovering && ble.streams.isEmpty { Text("This device exposes no notification streams.") }
                } header: { Text("Data streams") } footer: {
                    Text("Enable the characteristics documented by the device manufacturer. Some devices need a firmware-specific start command.")
                }
                Section {
                    Toggle("Record with sessions", isOn: $ble.includeInSessions)
                        .disabled(ble.configurationLocked || model.active != nil)
                    if ble.ready {
                        Label("Ready for your next session", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } footer: {
                    Text("Start and finish from Home. Bluetooth payloads are added to that session’s ZIP. Keep SCOPE in the foreground. Pausing phone sensors leaves the Bluetooth stream recording.")
                }
                Section("Device details") {
                    if !ble.manufacturer.isEmpty { LabeledContent("Manufacturer", value: ble.manufacturer) }
                    if !ble.modelNumber.isEmpty { LabeledContent("Model", value: ble.modelNumber) }
                    if !ble.serialNumber.isEmpty { LabeledContent("Serial", value: ble.serialNumber) }
                    if let id = ble.connectedID {
                        LabeledContent("iOS identifier") { Text(id.uuidString).font(.caption).textSelection(.enabled) }
                    }
                    Button("Disconnect", role: .destructive) { ble.disconnect() }
                        .disabled(ble.configurationLocked || model.active != nil)
                }
            }
            if ble.capturing || ble.receivedPackets > 0 {
                Section("This recording") {
                    LabeledContent("Payloads received", value: String(ble.receivedPackets))
                    LabeledContent("Payload bytes", value: ByteCountFormatter.string(fromByteCount: ble.receivedBytes, countStyle: .file))
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(ble.lastReceived.map {
                            timeline.date.timeIntervalSince($0) > 3 ? "No recent data" : "Receiving data"
                        } ?? "Waiting for first payload").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("Check for unattached recordings") { Task { await loadRecovery() } }
                    .disabled(model.active != nil || model.busy || ble.configurationLocked || savingRecovery)
                ForEach(recoveryFolders, id: \.path) { folder in
                    Button("Recover Bluetooth recording \(folder.lastPathComponent.prefix(8))") {
                        Task { await recover(folder) }
                    }.disabled(model.active != nil || model.busy || ble.configurationLocked || savingRecovery)
                }
                if savingRecovery { ProgressView() }
                if let recoveryMessage { Text(recoveryMessage).font(.footnote) }
            } header: { Text("Recovery") } footer: {
                Text("Unattached or interrupted captures stay on this phone. Recovery creates a separate session and preserves the original capture status.")
            }
        }
        .navigationTitle("Bluetooth devices")
        .alert("Device label", isPresented: $rename) {
            TextField("For example, Chest sensor", text: $label)
            Button("Save") { ble.renameDevice(label) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saved in SCOPE; this does not rename the device firmware.") }
    }
    private func loadRecovery() async {
        recoveryFolders = await Task.detached(priority: .utility) {
            guard let root = try? BLEFileWriter.inboxURL(),
                  let folders = try? FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.isDirectoryKey]) else { return [URL]() }
            return folders.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("device.json").path)
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }.value
    }
    private func recover(_ folder: URL) async {
        savingRecovery = true; defer { savingRecovery = false }
        do {
            let content = try await Task.detached(priority: .utility) {
                let profile = try JSONDecoder().decode(ExternalDeviceProfile.self,
                    from: Data(contentsOf: folder.appendingPathComponent("device.json")))
                let files = try FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey]).filter {
                        (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    }
                return (profile, files)
            }.value
            let success = await model.importExternal(content.1, profile: content.0, sessionID: nil,
                title: String("Recovered \(content.0.name)".prefix(120)), source: "ble_recovered_capture")
            if success {
                await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }.value
                recoveryMessage = "Recovered to Sessions. Review capture.json for interruptions."
                await loadRecovery()
            }
        } catch { recoveryMessage = error.localizedDescription }
    }
}
