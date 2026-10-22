//
//  DevicesView.swift
//  SCOPECaptureCore
//
//  Created by MD. Raiyan Haque on 10/22/26.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ExternalAccessory
import Combine
import CryptoKit

@MainActor
final class DeviceProfiles: ObservableObject {
    @Published private(set) var profiles: [ExternalDeviceProfile] = []
    @Published var message: String?
    init() {
        if let data = UserDefaults.standard.data(forKey: "scope.externalDeviceProfiles") {
            do { profiles = try JSONDecoder().decode([ExternalDeviceProfile].self, from: data) }
            catch { message = "Saved device profiles could not be read. Your session data is unaffected." }
        }
    }
    func save(_ profile: ExternalDeviceProfile) {
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        do {
            let data = try JSONEncoder().encode(updated)
            UserDefaults.standard.set(data, forKey: "scope.externalDeviceProfiles")
            profiles = updated
        } catch { message = error.localizedDescription }
    }
}

/// Serial, bounded writes. Incoming bytes are never decoded or resampled.
/// The byte stream and receipt index remain in Application Support until imported.
final class RawAccessoryWriter: @unchecked Sendable {
    let folder: URL
    let files: [URL]
    private let queue = DispatchQueue(label: "scope.wired.writer", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var failure: String?
    private var closing = false
    private let raw: FileHandle
    private let index: FileHandle
    private var offset: UInt64 = 0
    private var digest = SHA256()
    private var lastSync = Date()
    private var lastSpaceCheck: UInt64 = 0
    private let profile: ExternalDeviceProfile
    private let protocolName: String
    private let startedAt = Date()

    init(profile: ExternalDeviceProfile, protocolName: String) throws {
        self.profile = profile
        self.protocolName = protocolName
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var inbox = support.appendingPathComponent("ExternalInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        try inbox.setResourceValues(resource)
        folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        let payload = folder.appendingPathComponent("stream.bin")
        let receipts = folder.appendingPathComponent("receipts.jsonl")
        let description = folder.appendingPathComponent("capture.json")
        let profileFile = folder.appendingPathComponent("device.json")
        files = [payload, receipts, description, profileFile]
        try JSONEncoder().encode(profile).write(to: profileFile, options: .atomic)
        try Data().write(to: payload, options: .withoutOverwriting)
        try Data().write(to: receipts, options: .withoutOverwriting)
        raw = try FileHandle(forWritingTo: payload)
        index = try FileHandle(forWritingTo: receipts)
        let metadata: [String: String] = [
            "state": "open_or_interrupted", "protocol": protocolName, "deviceName": profile.name,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "timing": "Receipt times are phone arrival times, not hardware acquisition times.",
            "format": "Opaque byte stream in stream.bin. Receipt boundaries are transport chunks, not sample boundaries. External sampling is configured on the device."
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: description, options: .atomic)
    }

    func append(_ data: Data, elapsed: Double, epoch: Double) -> Bool {
        lock.lock()
        guard failure == nil, !closing else { lock.unlock(); return false }
        guard pending + data.count <= 4 * 1024 * 1024 else {
            failure = "Incoming data exceeded the bounded disk queue. Capture stopped; completeness cannot be guaranteed."
            lock.unlock(); return false
        }
        pending += data.count; lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); pending -= data.count; lock.unlock() }
            lock.lock(); let failed = failure != nil; lock.unlock()
            guard !failed else { return }
            do {
                if offset >= lastSpaceCheck {
                    let attributes = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
                    guard let free = attributes[.systemFreeSize] as? NSNumber,
                          free.int64Value > LocalStore.minimumFreeBytes else {
                        throw RecorderError(message: "Wired capture stopped at the free-space reserve.")
                    }
                    lastSpaceCheck = offset + 1024 * 1024
                }
                let row: [String: Any] = ["offset": offset, "bytes": data.count,
                    "received_elapsed_s": elapsed, "received_utc_epoch_s": epoch]
                var line = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
                line.append(10)
                try raw.write(contentsOf: data)
                try index.write(contentsOf: line)
                digest.update(data: data); offset += UInt64(data.count)
                if Date().timeIntervalSince(lastSync) >= 1 {
                    try raw.synchronize(); try index.synchronize(); lastSync = Date()
                }
            } catch {
                lock.lock(); failure = error.localizedDescription; lock.unlock()
            }
        }
        return true
    }

    func finish(reason: String?, completion: @escaping @Sendable (String?) -> Void) {
        lock.lock(); closing = true; lock.unlock()
        queue.async { [self] in
            lock.lock(); var issue = failure ?? reason; lock.unlock()
            do { try raw.synchronize(); try index.synchronize(); try raw.close(); try index.close() }
            catch { issue = issue ?? error.localizedDescription }
            do {
                let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
                let actual = try SessionFiles.fingerprint(files[0])
                guard actual.0 == Int64(offset), actual.1 == hash else {
                    throw RecorderError(message: "Raw capture failed post-write verification.")
                }
                let metadata: [String: Any] = [
                    "state": issue == nil ? "closed_not_device_verified" : "incomplete",
                    "deviceName": profile.name, "protocol": protocolName, "bytes": offset, "sha256": hash,
                    "startedAt": ISO8601DateFormatter().string(from: startedAt),
                    "endedAt": ISO8601DateFormatter().string(from: Date()),
                    "issue": issue ?? "",
                    "timing": "receipts.jsonl contains phone receive times. They are not device acquisition times.",
                    "completeness": "Checksums verify stored bytes; device-side completeness requires the manufacturer's framing and sequence/checksum protocol."
                ]
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: files[2], options: .atomic)
            } catch { issue = issue ?? error.localizedDescription }
            completion(issue)
        }
    }
}

@MainActor
final class WiredAccessoryController: NSObject, ObservableObject, @preconcurrency StreamDelegate {
    @Published private(set) var accessories: [EAAccessory] = []
    @Published private(set) var connectedID: Int?
    @Published private(set) var status = "Not connected"
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var lastReceived: Date?
    @Published private(set) var capturing = false
    @Published private(set) var finalizing = false
    @Published private(set) var completedFiles: [URL] = []
    @Published private(set) var completedProfile: ExternalDeviceProfile?
    @Published private(set) var issue: String?
    private var session: EASession?
    private var input: InputStream?
    private var writer: RawAccessoryWriter?
    private var anchor: TimeInterval = 0
    private var byteCount: Int64 = 0
    private var latestDataTime: Date?
    private var lastPublication = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    var supportedProtocols: [String] { Bundle.main.object(forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols") as? [String] ?? [] }

    override init() {
        super.init()
        EAAccessoryManager.shared().registerForLocalNotifications()
        for name in [Notification.Name.EAAccessoryDidConnect, .EAAccessoryDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func refresh() {
        accessories = EAAccessoryManager.shared().connectedAccessories
        if let connectedID, !accessories.contains(where: { $0.connectionID == connectedID }) {
            stop(reason: "Accessory disconnected. A partial capture may have been saved.")
        }
        if capturing, let latestDataTime, Date().timeIntervalSince(latestDataTime) > 2 {
            status = "Connected · no recent data"
        }
    }
    func connect(_ accessory: EAAccessory) {
        guard !capturing, !finalizing else { return }
        disconnect()
        guard let protocolName = accessory.protocolStrings.first(where: supportedProtocols.contains) else {
            issue = "This accessory needs a manufacturer-supported protocol in the app configuration. A cable alone is insufficient."
            return
        }
        guard let value = EASession(accessory: accessory, forProtocol: protocolName), let stream = value.inputStream else {
            issue = "iOS could not open the accessory session. Check device authorization and its manufacturer's integration requirements."
            return
        }
        session = value; input = stream; connectedID = accessory.connectionID
        stream.delegate = self; stream.schedule(in: .main, forMode: .common); stream.open()
        status = "Connecting"; issue = nil
    }
    func start(profile: ExternalDeviceProfile) {
        guard input?.streamStatus == .open || input?.streamStatus == .reading,
              let session, let protocolName = session.protocolString, !capturing, !finalizing else { return }
        do {
            writer = try RawAccessoryWriter(profile: profile, protocolName: protocolName)
            completedProfile = profile
            completedFiles = []; receivedBytes = 0; lastReceived = nil; issue = nil
            byteCount = 0; latestDataTime = nil; lastPublication = .distantPast
            anchor = ProcessInfo.processInfo.systemUptime; capturing = true; status = "Waiting for data"
        } catch { issue = error.localizedDescription }
    }
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard aStream === input else { return }
        switch eventCode {
        case .openCompleted: status = "Connected"
        case .hasBytesAvailable: readAvailable()
        case .errorOccurred: stop(reason: aStream.streamError?.localizedDescription ?? "Accessory stream failed.")
        case .endEncountered: stop(reason: "The device ended its stream. Review capture completeness.")
        default: break
        }
    }
    private func readAvailable() {
        guard let input else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        var budget = 4
        while input.hasBytesAvailable && budget > 0 {
            budget -= 1
            let count = input.read(&bytes, maxLength: bytes.count)
            if count < 0 { stop(reason: input.streamError?.localizedDescription ?? "Read failed."); return }
            guard count > 0 else { return }
            let now = Date()
            if capturing, let writer {
                guard writer.append(Data(bytes.prefix(count)), elapsed: ProcessInfo.processInfo.systemUptime - anchor,
                                    epoch: now.timeIntervalSince1970) else {
                    stop(reason: "Disk writes could not keep up or failed. Review the partial capture."); return
                }
                byteCount += Int64(count); latestDataTime = now
                if now.timeIntervalSince(lastPublication) >= 0.25 {
                    receivedBytes = byteCount; lastReceived = now; lastPublication = now
                }
                if status != "Receiving data" { status = "Receiving data" }
            } else {
                if status != "Connected · not recording" { status = "Connected · not recording" }
            }
        }
        if input.hasBytesAvailable {
            DispatchQueue.main.async { [weak self] in self?.readAvailable() }
        }
    }
    func stop(reason: String? = nil) {
        let pendingWriter = writer; writer = nil; capturing = false
        receivedBytes = byteCount; lastReceived = latestDataTime
        closeStream()
        if let reason { issue = reason }
        guard let pendingWriter else { status = "Not connected"; return }
        finalizing = true; status = "Saving capture"
        pendingWriter.finish(reason: reason) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                completedFiles = pendingWriter.files; finalizing = false
                issue = error; status = error == nil ? "Capture saved" : "Partial capture saved"
            }
        }
    }
    func disconnect() { stop() }
    private func closeStream() {
        input?.close(); input?.remove(from: .main, forMode: .common); input?.delegate = nil
        input = nil; session = nil; connectedID = nil
    }
}

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceProfiles
    @EnvironmentObject private var wired: WiredAccessoryController
    @State private var profileID: UUID?
    @State private var editing: ExternalDeviceProfile?
    @State private var picker = false
    @State private var sessionID: UUID?
    @State private var title = "External recording"
    @State private var result: String?
    @State private var inbox: [URL] = []
    private var profile: ExternalDeviceProfile? { devices.profiles.first { $0.id == profileID } }
    private var selectableSessions: [ResearchSession] {
        model.sessions.filter { $0.schemaVersion >= 2 && ($0.state.exportable || ($0.selected.isEmpty && $0.state == .incomplete)) }
    }
    private var ready: Bool { profile != nil && model.active == nil && !model.busy && !wired.capturing && !wired.finalizing }

    var body: some View {
        List {
            Section {
                Label("External data", systemImage: "cable.connector")
                    .font(.title2.weight(.semibold)).padding(.vertical, 6)
                Text("Keep original files. Capture supported wired streams.")
                    .foregroundStyle(.secondary)
            }
            Section("Device") {
                Picker("Profile", selection: $profileID) {
                    Text("Choose device").tag(Optional<UUID>.none)
                    ForEach(devices.profiles) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(wired.capturing || wired.finalizing)
                Button { editing = ExternalDeviceProfile(name: "", manufacturer: "", model: "", notes: "") } label: {
                    Label("Add device", systemImage: "plus")
                }.disabled(wired.capturing || wired.finalizing)
                if let profile {
                    Button("Edit device details") { editing = profile }.disabled(wired.capturing || wired.finalizing)
                }
                if let message = devices.message { Text(message).font(.footnote).foregroundStyle(.orange) }
            }
            Section("Save to session") {
                Picker("Session", selection: $sessionID) {
                    Text("New external session").tag(Optional<UUID>.none)
                    ForEach(selectableSessions) { Text($0.experiment).tag(Optional($0.id)) }
                }.disabled(model.busy)
                if sessionID == nil { TextField("Session name", text: $title).disabled(model.busy) }
                if model.active != nil { Text("Finish your phone recording before importing or attaching files.").font(.footnote) }
            }
            Section {
                Button { picker = true } label: {
                    Label(model.busy ? "Copying & checking…" : "Import original files", systemImage: "square.and.arrow.down")
                }.disabled(!ready || (sessionID == nil && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                if model.busy { ProgressView() }
                if let result { Label(result, systemImage: "checkmark.circle").foregroundStyle(.tint) }
            } header: { Text("Files from a logger") } footer: {
                Text("Choose any file type from Files, including an external drive visible to iOS. Originals are copied without conversion and checked with SHA-256. Importing does not establish a live device connection.")
            }
            Section {
                LabeledContent("Status", value: wired.status)
                if wired.capturing || wired.receivedBytes > 0 {
                    LabeledContent("Received", value: ByteCountFormatter.string(fromByteCount: wired.receivedBytes, countStyle: .file))
                    if let last = wired.lastReceived { LabeledContent("Last data", value: last.formatted(date: .omitted, time: .standard)) }
                }
                ForEach(wired.accessories, id: \.connectionID) { accessory in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(accessory.name).font(.headline)
                        Text("\(accessory.manufacturer) · \(accessory.modelNumber)").font(.caption).foregroundStyle(.secondary)
                        Button(wired.connectedID == accessory.connectionID ? "Connected" : "Connect") { wired.connect(accessory) }
                            .disabled(wired.connectedID == accessory.connectionID || wired.capturing || wired.finalizing)
                    }
                }
                if wired.accessories.isEmpty { Text("No supported accessory reported by iOS").foregroundStyle(.secondary) }
                if wired.supportedProtocols.isEmpty {
                    Text("Live capture needs the device manufacturer's supported iOS protocol. No device protocol is configured in this build.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if wired.connectedID != nil && !wired.capturing {
                    Button("Start raw capture") { if let profile { wired.start(profile: profile) } }
                        .disabled(profile == nil || wired.finalizing)
                }
                if wired.capturing { Button("Stop & save capture") { wired.stop() } }
                else if wired.connectedID != nil { Button("Disconnect") { wired.disconnect() } }
                if wired.finalizing { ProgressView("Verifying capture…") }
                if let issue = wired.issue { Text(issue).font(.footnote).foregroundStyle(.orange) }
                if !wired.completedFiles.isEmpty {
                    Button("Attach saved capture to session") { attach(wired.completedFiles, source: "external_accessory_stream", capturedProfile: wired.completedProfile) }
                        .disabled(!ready)
                }
            } header: { Text("Live wired accessory") } footer: {
                Text("Connected means iOS opened an accessory stream. Receiving data means bytes arrived. Capture preserves raw bytes as BIN with a separate receipt-time index; it does not decode samples or set the device's rate.")
            }
            if !inbox.isEmpty {
                Section("Retained captures") {
                    ForEach(inbox, id: \.self) { folder in
                        Button("Import capture \(folder.lastPathComponent.prefix(8))") {
                            let files = ["stream.bin", "receipts.jsonl", "capture.json", "device.json"].map { folder.appendingPathComponent($0) }
                            let savedProfile = (try? Data(contentsOf: folder.appendingPathComponent("device.json")))
                                .flatMap { try? JSONDecoder().decode(ExternalDeviceProfile.self, from: $0) }
                            attach(files, source: "retained_accessory_capture", capturedProfile: savedProfile)
                        }.disabled(!ready)
                    }
                    Text("Retained captures may include interrupted recordings. Review capture.json and receipt continuity before analysis. Originals stay on this phone after attachment.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                DisclosureGroup("Cable compatibility") {
                    Text("A USB-C port does not give apps generic USB serial access. Lightning iPhones may require a compatible host adapter and device power; a USB-C-to-Lightning charging cable alone is not a universal data connection. Use a manufacturer-supported iOS accessory or import files from a storage device visible in Files.")
                    Text("100 Hz applies to the phone's motion recording. An external device keeps its own sampling rate and file format.")
                }
            }
        }
        .navigationTitle("Devices")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { wired.refresh(); loadInbox() } label: { Image(systemName: "arrow.clockwise") } } }
        .task { wired.refresh(); loadInbox(); await model.refresh(); if profileID == nil { profileID = devices.profiles.first?.id } }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                wired.refresh()
            }
        }
        .sheet(item: $editing) { value in DeviceProfileEditor(profile: value) { devices.save($0); profileID = $0.id } }
        .sheet(isPresented: $picker) { OriginalFilePicker { urls in picker = false; if !urls.isEmpty { attach(urls) } } }
    }
    private func attach(_ urls: [URL], source: String = "document_picker", capturedProfile: ExternalDeviceProfile? = nil) {
        guard let profile = capturedProfile ?? profile else { return }
        result = nil
        Task {
            let ok = await model.importExternal(urls, profile: profile, sessionID: sessionID, title: title, source: source)
            if ok { result = "Files verified and added to Sessions" }
            loadInbox()
        }
    }
    private func loadInbox() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let root = support.appendingPathComponent("ExternalInbox")
        inbox = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

private struct DeviceProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: ExternalDeviceProfile
    let save: (ExternalDeviceProfile) -> Void
    var body: some View {
        NavigationStack {
            Form {
                TextField("Device name", text: $profile.name)
                TextField("Manufacturer (optional)", text: $profile.manufacturer)
                TextField("Model (optional)", text: $profile.model)
                TextField("Research notes (optional)", text: $profile.notes, axis: .vertical).lineLimit(3...6)
            }
            .navigationTitle("Device details").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines); save(profile); dismiss() }
                        .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.name.count > 120 || profile.manufacturer.count > 120 || profile.model.count > 120 || profile.notes.count > 2000)
                }
            }
        }
    }
}

private struct OriginalFilePicker: UIViewControllerRepresentable {
    let completion: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        controller.allowsMultipleSelection = true; controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: ([URL]) -> Void
        init(completion: @escaping ([URL]) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion([]) }
    }
}
