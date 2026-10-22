import Foundation
import SwiftUI
import CoreBluetooth
import Combine
import UIKit

struct BluetoothDeviceRow: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

struct BluetoothFieldRow: Identifiable {
    let id: UUID
    let service: String
    let characteristic: String
    let readable: Bool
    let notifiable: Bool

    var preview = "No value received"
}

@MainActor
final class BluetoothSetup: NSObject, ObservableObject,
    @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate {

    @Published private(set) var status = "Ready to find your device"
    @Published private(set) var devices: [BluetoothDeviceRow] = []
    @Published private(set) var fields: [BluetoothFieldRow] = []

    @Published private(set) var scanning = false
    @Published private(set) var connected = false
    @Published private(set) var selectedName: String?
    @Published private(set) var listening: UUID?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var selected: CBPeripheral?

    private var characteristics: [UUID: CBCharacteristic] = [:]
    private var pendingServices: Set<ObjectIdentifier> = []
    private var serviceIDs: [String] = []

    private var wantsScan = false
    private var discoveryFailed = false
    private var reportDevice = "No device selected"
    private var lastPreviewUpdate = Date.distantPast

    private var timeout: Task<Void, Never>?
    private var previewTimeout: Task<Void, Never>?

    func scan() {
        guard selected == nil else { return }

        // Prevent a privacy-key crash if project setup was missed.
        guard let explanation = Bundle.main.object(
            forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription"
        ) as? String,
        !explanation.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            status = "Add the Bluetooth usage description to Info.plist, then rebuild."
            return
        }

        wantsScan = true

        guard let central else {
            status = "Waiting for Bluetooth access…"

            self.central = CBCentralManager(
                delegate: self,
                queue: .main
            )
            return
        }

        switch central.state {
        case .poweredOn:
            beginScan()

        case .unknown, .resetting:
            status = "Preparing Bluetooth…"

        default:
            wantsScan = false
            updateRadioStatus()
        }
    }

    private func beginScan() {
        guard wantsScan,
              selected == nil,
              let central,
              central.state == .poweredOn else {
            return
        }

        wantsScan = false
        devices.removeAll()
        peripherals.removeAll()

        scanning = true
        status = "Searching nearby…"

        central.scanForPeripherals(
            withServices: nil,
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ]
        )

        timeout?.cancel()

        timeout = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(12))
            } catch {
                return
            }

            self?.stopScan()
        }
    }

    func stopScan() {
        wantsScan = false
        central?.stopScan()
        scanning = false

        timeout?.cancel()
        timeout = nil

        if selected == nil {
            status = devices.isEmpty
                ? "No devices found. Check the board’s power and firmware."
                : "Select your research board below."
        }
    }

    func connect(_ id: UUID) {
        guard selected == nil,
              central?.state == .poweredOn,
              let peripheral = peripherals[id] else {
            return
        }

        stopScan()

        selected = peripheral
        selectedName = devices.first {
            $0.id == id
        }?.name ?? "Unnamed device"

        reportDevice =
            "\(selectedName ?? "Unnamed device")\n" +
            "Local iOS identifier: \(id.uuidString)"

        connected = false
        discoveryFailed = false

        fields.removeAll()
        characteristics.removeAll()
        pendingServices.removeAll()
        serviceIDs.removeAll()

        peripheral.delegate = self
        status = "Connecting…"

        central?.connect(peripheral, options: nil)
        armConnectionTimeout()
    }

    private func armConnectionTimeout() {
        timeout?.cancel()

        timeout = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }

            guard let self else { return }

            self.disconnect()
            self.status = "Connection or discovery timed out. Try again."
        }
    }

    func disconnect() {
        timeout?.cancel()
        timeout = nil

        stopPreview()

        let previous = selected

        selected = nil
        selectedName = nil
        connected = false

        pendingServices.removeAll()
        previous?.delegate = nil

        if let previous {
            central?.cancelPeripheralConnection(previous)
        }

        status = "Disconnected"
    }

    func close() {
        stopScan()
        disconnect()
    }

    func read(_ id: UUID) {
        guard connected,
              let selected,
              let characteristic = characteristics[id],
              characteristic.properties.contains(.read) else {
            return
        }

        selected.readValue(for: characteristic)
    }

    func preview(_ id: UUID) {
        guard connected,
              let selected,
              let characteristic = characteristics[id],
              characteristic.properties.contains(.notify)
                || characteristic.properties.contains(.indicate) else {
            return
        }

        stopPreview()

        listening = id
        lastPreviewUpdate = .distantPast

        selected.setNotifyValue(
            true,
            for: characteristic
        )

        previewTimeout = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }

            self?.stopPreview()
        }
    }

    func stopPreview() {
        previewTimeout?.cancel()
        previewTimeout = nil

        if let listening,
           let characteristic = characteristics[listening],
           let selected,
           selected.state == .connected {
            selected.setNotifyValue(
                false,
                for: characteristic
            )
        }

        listening = nil
    }

    private func updateRadioStatus() {
        guard let central else {
            status = "Ready to find your device"
            return
        }

        switch central.state {
        case .poweredOn:
            status = "Bluetooth ready"

        case .poweredOff:
            status = "Turn on Bluetooth in iPhone Settings."

        case .unauthorized:
            status = "Allow SCOPE Bluetooth access in iPhone Settings."

        case .unsupported:
            status = "Bluetooth LE is unavailable on this device."

        case .resetting:
            status = "Bluetooth is restarting…"

        case .unknown:
            status = "Checking Bluetooth…"

        @unknown default:
            status = "Bluetooth state is unavailable."
        }
    }

    func centralManagerDidUpdateState(
        _ central: CBCentralManager
    ) {
        if central.state == .poweredOn {
            updateRadioStatus()

            if wantsScan {
                beginScan()
            }

            return
        }

        let shouldRetry = wantsScan
            && (
                central.state == .unknown
                || central.state == .resetting
            )

        close()
        wantsScan = shouldRetry
        updateRadioStatus()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard scanning,
              peripherals[peripheral.identifier] != nil
                || peripherals.count < 80 else {
            return
        }

        peripherals[peripheral.identifier] = peripheral

        let name =
            advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name
            ?? "Unnamed device"

        let row = BluetoothDeviceRow(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue
        )

        if let index = devices.firstIndex(
            where: { $0.id == row.id }
        ) {
            devices[index] = row
        } else {
            devices.append(row)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        guard peripheral === selected else { return }

        connected = true
        status = "Discovering device services…"

        armConnectionTimeout()
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral === selected else { return }

        disconnect()
        status = error?.localizedDescription ?? "Connection failed."
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral === selected else { return }

        disconnect()
        status = error?.localizedDescription ?? "The device disconnected."
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard peripheral === selected else { return }

        if let error {
            disconnect()
            status = error.localizedDescription
            return
        }

        let services = peripheral.services ?? []

        serviceIDs = services.map {
            $0.uuid.uuidString
        }

        pendingServices = Set(
            services.map { ObjectIdentifier($0) }
        )

        for service in services {
            peripheral.discoverCharacteristics(
                nil,
                for: service
            )
        }

        finishDiscoveryIfReady()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral === selected else { return }

        pendingServices.remove(ObjectIdentifier(service))

        if error != nil {
            discoveryFailed = true
        }

        for characteristic in service.characteristics ?? [] {
            let id = UUID()

            characteristics[id] = characteristic

            fields.append(
                BluetoothFieldRow(
                    id: id,
                    service: service.uuid.uuidString,
                    characteristic: characteristic.uuid.uuidString,
                    readable: characteristic.properties.contains(.read),
                    notifiable:
                        characteristic.properties.contains(.notify)
                        || characteristic.properties.contains(.indicate)
                )
            )
        }

        finishDiscoveryIfReady()
    }

    private func finishDiscoveryIfReady() {
        guard pendingServices.isEmpty else { return }

        timeout?.cancel()
        timeout = nil

        status = discoveryFailed
            ? "Connected. Some services could not be inspected."
            : "Connected · \(fields.count) characteristics found"
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === selected,
              let id = characteristics.first(
                where: { $0.value === characteristic }
              )?.key,
              let index = fields.firstIndex(
                where: { $0.id == id }
              ) else {
            return
        }

        if let error {
            fields[index].preview = error.localizedDescription
            return
        }

        if listening == id {
            let now = Date()

            guard now.timeIntervalSince(lastPreviewUpdate) >= 0.2 else {
                return
            }

            lastPreviewUpdate = now
        }

        let data = characteristic.value ?? Data()

        let hex = data.prefix(64)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")

        fields[index].preview =
            "\(data.count) bytes: \(hex)" +
            (data.count > 64 ? " …" : "")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === selected else { return }

        if let error {
            status = error.localizedDescription

            let active = listening.flatMap {
                characteristics[$0]
            }

            if active === characteristic {
                previewTimeout?.cancel()
                previewTimeout = nil
                listening = nil
            }
        }
    }

    var report: String {
        let header = [
            "SCOPE Bluetooth discovery report",
            "Diagnostic preview only; not a research recording.",
            reportDevice,
            status,
            "Services: " + serviceIDs.joined(separator: ", ")
        ]

        let details = fields.map {
            """
            Service: \($0.service)
            Characteristic: \($0.characteristic)
            Readable: \($0.readable)
            Notifications: \($0.notifiable)
            Preview: \($0.preview)
            """
        }

        return (header + details).joined(separator: "\n\n")
    }
}

@MainActor
struct BluetoothSetupView: View {
    @StateObject private var bluetooth = BluetoothSetup()

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        bluetooth.selectedName ?? "Research device",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                    .font(.headline)

                    Text(bluetooth.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if bluetooth.selectedName != nil {
                        Button(
                            "Disconnect",
                            role: .destructive
                        ) {
                            bluetooth.disconnect()
                        }
                    } else {
                        Button {
                            if bluetooth.scanning {
                                bluetooth.stopScan()
                            } else {
                                bluetooth.scan()
                            }
                        } label: {
                            HStack {
                                if bluetooth.scanning {
                                    ProgressView()
                                }

                                Text(
                                    bluetooth.scanning
                                        ? "Stop search"
                                        : "Find device"
                                )
                            }
                        }
                    }
                } footer: {
                    Text(
                        "Connect to your research board. " +
                        "This screen checks its Bluetooth interface; " +
                        "it does not save sensor measurements."
                    )
                }

                if bluetooth.selectedName == nil {
                    Section {
                        if bluetooth.devices.isEmpty {
                            Text(
                                bluetooth.scanning
                                    ? "Looking for nearby devices…"
                                    : "Tap Find device to search."
                            )
                            .foregroundStyle(.secondary)
                        }

                        ForEach(bluetooth.devices) { device in
                            Button {
                                bluetooth.connect(device.id)
                            } label: {
                                HStack {
                                    VStack(
                                        alignment: .leading,
                                        spacing: 4
                                    ) {
                                        Text(device.name)
                                            .foregroundStyle(.primary)

                                        Text(device.id.uuidString)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    } header: {
                        Text("Nearby devices")
                    }
                }

                if !bluetooth.fields.isEmpty {
                    Section {
                        ForEach(bluetooth.fields) { field in
                            DisclosureGroup {
                                Text("Service: \(field.service)")
                                    .font(.caption.monospaced())

                                Text(field.preview)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)

                                if field.readable {
                                    Button("Read value") {
                                        bluetooth.read(field.id)
                                    }
                                    .disabled(!bluetooth.connected)
                                }

                                if field.notifiable {
                                    Button(
                                        bluetooth.listening == field.id
                                            ? "Stop preview"
                                            : "Preview for 10 seconds"
                                    ) {
                                        if bluetooth.listening == field.id {
                                            bluetooth.stopPreview()
                                        } else {
                                            bluetooth.preview(field.id)
                                        }
                                    }
                                    .disabled(!bluetooth.connected)
                                }
                            } label: {
                                Text(field.characteristic)
                                    .font(.subheadline.monospaced())
                            }
                        }
                    } header: {
                        Text("Device interface")
                    }

                    Section {
                        ShareLink(
                            item: bluetooth.report
                        ) {
                            Label(
                                "Share device report",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                    }
                }

                Section {
                    Button("Open app settings") {
                        guard let url = URL(
                            string: UIApplication.openSettingsURLString
                        ) else {
                            return
                        }

                        UIApplication.shared.open(url)
                    }

                    DisclosureGroup("Board not appearing?") {
                        Text(
                            "The board must be powered and running firmware " +
                            "that advertises over Bluetooth LE. An empty board " +
                            "will not appear simply because it is plugged in."
                        )

                        Text(
                            "Check Bluetooth is on and SCOPE has permission. " +
                            "Close any other app connected to the board, " +
                            "then search again."
                        )
                    }
                    .font(.footnote)
                }
            }
            .navigationTitle("External device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        bluetooth.close()
                        dismiss()
                    }
                }
            }
            .onChange(of: phase) { _, newPhase in
                if newPhase == .background {
                    bluetooth.close()
                }
            }
            .onDisappear {
                bluetooth.close()
            }
        }
    }
}
