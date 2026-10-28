import Foundation
import SwiftUI
import UIKit

struct AppMessage: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
}
struct ExportItem: Identifiable {
    let id = UUID()
    var url: URL
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [ResearchSession] = []
    @Published private(set) var catalogIssues: [String] = []
    @Published private(set) var active: ResearchSession?
    @Published private(set) var paused = false
    @Published private(set) var busy = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var freeBytes: Int64 = 0
    @Published private(set) var storage: StorageSnapshot?
    @Published var message: AppMessage?
    @Published var exportItem: ExportItem?
    @Published var selectedTab = 0
    let hub = SensorHub()
    weak var bluetooth: BLERecorder?
    private var store: LocalStore?
    private var buffer: SampleBuffer?
    private var timer: Task<Void, Never>?
    private var checkpointing = false
    private var nextCheckpointElapsed: Double = 0
    private var foreground = true
    private var keepAwake = false
    private var previousIdleSetting = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastExport: URL?

    init() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            store = try LocalStore(root: support.appendingPathComponent("ResearchSessions", isDirectory: true))
        } catch {
            message = AppMessage(title: "Storage unavailable", detail: error.localizedDescription)
        }
    }
    
    var researchElapsed: Double {
        buffer?.elapsedNow() ?? elapsed
    }

    func researchSamples() -> [Sensor: SampleRow] {
        buffer?.preview() ?? [:]
    }
    
    var canStart: Bool { store != nil && active == nil && !busy && hub.requesting == nil }
    var storageText: String {
        guard let storage else { return "Unavailable — refresh to retry" }
        return ByteCountFormatter.string(fromByteCount: storage.available, countStyle: .file)
    }
    var available: [Sensor] { hub.available }
    var status: String { busy ? "Saving" : paused ? "Paused" : "Recording" }

    func rename(_ id: UUID, title: String) async {
        guard active == nil, !busy, let store else { return }
        busy = true; defer { busy = false }
        do { try await store.rename(id, title: title); await refresh() }
        catch { message = AppMessage(title: "Could not rename session", detail: error.localizedDescription) }
    }

    @discardableResult
    func importExternal(_ urls: [URL], profile: ExternalDeviceProfile, sessionID: UUID?, title: String,
                        source: String = "document_picker") async -> Bool {
        guard active == nil, !busy, let store else {
            message = AppMessage(title: "Finish recording first", detail: "Finish your phone session before attaching external files.")
            return false
        }
        busy = true; defer { busy = false }
        do {
            let id: UUID
            if let sessionID { id = sessionID }
            else {
                let created = try await store.createExternalSession(title: title,
                    device: "\(hub.deviceDescription) · hardware \(hub.hardwareModel)", os: UIDevice.current.systemVersion,
                    app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                id = created.id
            }
            try await store.attachExternalFiles(urls, to: id, device: profile, source: source)
            await refresh()
            return true
        } catch {
            await refresh()
            message = AppMessage(title: "Import did not complete", detail: error.localizedDescription + " Source files remain unchanged.")
            return false
        }
    }

    func refresh() async {
        hub.refreshPermissions()
        guard let store else { return }
        let result = await store.catalog()
        sessions = result.sessions; catalogIssues = result.issues
        storage = try? await store.storageSnapshot()
        if let storage { freeBytes = storage.available }
    }
    func start(experiment: String, participant: String, notes: String, protocolCode: String,
               selected: [Sensor], plannedSeconds: Double?, keepAwake: Bool) async throws {
        guard canStart, let store else { throw RecorderError(message: "The recorder is not ready.") }
        guard !selected.isEmpty, selected.allSatisfy({ hub.enabled.contains($0) && hub.ready($0) }) else {
            throw RecorderError(message: "Open Sensors and enable the sensors you need. Allow any requested permissions before starting.")
        }
        guard experiment.count <= 120, participant.count <= 80, protocolCode.count <= 80, notes.count <= 4_000 else {
            throw RecorderError(message: "Use a shorter session title, code, or note.")
        }
        busy = true; defer { busy = false }
        let sink = SampleBuffer()
        try await bluetooth?.prepareLinkedCapture()
        defer { bluetooth?.discardPreparedCapture() }
        if bluetooth?.includeInSessions == true, !foreground {
            throw RecorderError(message: "Keep SCOPE in the foreground before starting a Bluetooth recording.")
        }
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "Unknown"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "Unknown"
        let recordedAppVersion = "\(version) (\(build))"
        let session = try await store.begin(experiment: experiment.trimmingCharacters(in: .whitespacesAndNewlines),
            participant: participant.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes,
            protocolCode: protocolCode, selected: selected, available: available,
            device: "\(hub.deviceDescription) · hardware \(hub.hardwareModel)", os: UIDevice.current.systemVersion, app: recordedAppVersion,
            plannedSeconds: plannedSeconds, buffer: sink)
        buffer = sink; active = session; elapsed = 0; paused = !foreground
        bluetooth?.beginLinkedCapture(sessionID: session.id)
        if bluetooth?.capturing == true {
            sink.event("BLE_CAPTURE_START", "Phone receive times are stored in BLE packets.jsonl. Manual phone-sensor pauses do not pause BLE. External sample rate is controlled by device firmware.")
        }
        nextCheckpointElapsed = 1
        self.keepAwake = keepAwake
        previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
        sink.event("SESSION_START", "Foreground-only acquisition. Participant code is researcher supplied.")
        if foreground {
            hub.start(selected: selected, buffer: sink)
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        } else { sink.event("INTERRUPTION_START", "App became inactive before acquisition started.") }
        selectedTab = 0
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                guard let self else { break }
                await self.tick()
            }
        }
    }
    private func tick() async {
        guard let active, let buffer, !busy else { return }
        elapsed = buffer.elapsedNow()
        if let target = active.plannedSeconds, elapsed >= target {
            buffer.event("TARGET_REACHED", "The configured session duration was reached, including paused time.")
            await finish(); return
        }
        if elapsed >= nextCheckpointElapsed {
            nextCheckpointElapsed = elapsed + 5
            await checkpoint()
        }
    }
    private func checkpoint() async {
        guard !checkpointing, let session = active, let buffer, let store else { return }
        checkpointing = true; defer { checkpointing = false }
        do {
            let updated = try await store.checkpoint(id: session.id, buffer: buffer)
            if active?.id == session.id, !busy, let updated { active = updated }
            storage = try? await store.storageSnapshot()
            if let storage { freeBytes = storage.available }
        } catch {
            // A concurrent finalization owns its own error handling.
            if !busy, self.active?.id == session.id { await abort(error.localizedDescription) }
        }
    }
    func pause(interruption: Bool = false) {
        guard active != nil, !paused, !busy else { return }
        hub.stop(); paused = true
        UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
        buffer?.event(interruption ? "INTERRUPTION_START" : "MANUAL_PAUSE",
            interruption ? "App became inactive. Collection remains paused until Resume is tapped." : "Researcher paused acquisition.")
    }
    func resume() {
        guard let active, let buffer, paused, foreground, !busy else { return }
        guard active.selected.allSatisfy(hub.ready) else {
            message = AppMessage(title: "Sensor access changed", detail: "Restore the required permission in iOS Settings before resuming, or finish this session and configure a new one in Sensors.")
            return
        }
        buffer.event("RESUME", "Researcher resumed acquisition; elapsed time includes the pause.")
        hub.start(selected: active.selected, buffer: buffer)
        paused = false; UIApplication.shared.isIdleTimerDisabled = keepAwake
    }
    func sceneChanged(_ phase: ScenePhase) {
        foreground = phase == .active
        if phase != .active {
            pause(interruption: true)
            guard active != nil else { return }
            beginBackgroundTask()
            Task { [weak self] in
                guard let self else { return }
                await self.checkpoint()
                self.endBackgroundTask()
            }
        } else {
            if let buffer { elapsed = buffer.elapsedNow() }
            Task { await refresh() }
        }
    }
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save research checkpoint") { [weak self] in
            Task { @MainActor [weak self] in self?.endBackgroundTask() }
        }
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
    func marker(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active != nil, !busy, !value.isEmpty else { return }
        buffer?.event("MARKER", String(value.prefix(240)))
    }
    func finish() async {
        guard let session = active, let sink = buffer, let store, !busy else { return }
        busy = true
        let end = sink.elapsedNow()
        sink.event("SESSION_STOP", "Researcher or duration limit stopped acquisition.")
        hub.stop(); sink.seal(); timer?.cancel(); timer = nil
        UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
        beginBackgroundTask()
        let bluetoothCapture = await bluetooth?.finishLinkedCapture(sessionID: session.id)
        do {
            _ = try await store.finish(id: session.id, buffer: sink, endElapsed: end)
            active = nil; buffer = nil; paused = false; busy = false
            if let bluetoothCapture { await attachBluetooth(bluetoothCapture) }
            await refresh(); selectedTab = 1
        } catch {
            try? await store.fail(id: session.id, message: error.localizedDescription)
            active = nil; buffer = nil; paused = false; busy = false
            message = AppMessage(title: "Session needs recovery", detail: error.localizedDescription + " Open Sessions to inspect and recover the saved files.")
            await refresh(); selectedTab = 1
        }
        endBackgroundTask()
    }
    private func abort(_ detail: String) async {
        guard let active else { return }
        busy = true; hub.stop(); buffer?.seal(); timer?.cancel(); timer = nil
        _ = await bluetooth?.finishLinkedCapture(sessionID: active.id, reason: detail)
        UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
        do { try await store?.fail(id: active.id, message: detail) }
        catch { catalogIssues.append("Could not persist failure state: " + error.localizedDescription) }
        self.active = nil; buffer = nil; paused = false; busy = false
        message = AppMessage(title: "Recording stopped", detail: detail + " Saved data remains on this device. Recover the session before exporting.")
        await refresh(); selectedTab = 1
    }

    private func attachBluetooth(_ capture: BLECaptureResult) async {
        let success = await importExternal(capture.files, profile: capture.profile,
            sessionID: capture.sessionID, title: "Bluetooth recording", source: "ble_gatt_capture")
        if success {
            await Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: capture.folder)
            }.value
            if let issue = bluetooth?.issue {
                message = AppMessage(title: "Review Bluetooth recording",
                    detail: issue + " Received files were saved with the session. Review capture.json before analysis.")
            }
        }
    }
    func recover(_ id: UUID) async {
        guard active == nil, !busy, let store else { return }
        busy = true; defer { busy = false }
        do { _ = try await store.recover(id); await refresh() }
        catch { message = AppMessage(title: "Recovery unavailable", detail: error.localizedDescription + " The original files have not been deleted.") }
    }
    func export(_ id: UUID) async {
        guard active == nil, !busy, exportItem == nil, let store else { return }
        busy = true; defer { busy = false }
        do {
            let url = try await store.export(id)
            lastExport = url; exportItem = ExportItem(url: url)
        } catch { message = AppMessage(title: "Export unavailable", detail: error.localizedDescription) }
    }
    func exportDismissed() {
        guard let url = lastExport else { return }
        lastExport = nil
        Task { await store?.cleanExport(url) }
    }
    func delete(_ id: UUID) async {
        guard active == nil, !busy, let store else { return }
        busy = true; defer { busy = false }
        do { try await store.delete(id); await refresh() }
        catch { message = AppMessage(title: "Could not delete session", detail: error.localizedDescription) }
    }
}
