import Foundation
import CryptoKit

// MARK: - Versioned research format

enum Sensor: String, Codable, CaseIterable, Identifiable, Sendable {
    case accelerometer, gyroscope, deviceMotion, magnetometer
    case location, altitude, steps, proximity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accelerometer: return "Accelerometer"
        case .gyroscope: return "Gyroscope"
        case .deviceMotion: return "Device motion"
        case .magnetometer: return "Magnetometer"
        case .location: return "Location"
        case .altitude: return "Relative altitude"
        case .steps: return "Steps"
        case .proximity: return "Proximity"
        }
    }
    var symbol: String {
        switch self {
        case .accelerometer: return "waveform.path"
        case .gyroscope: return "rotate.3d"
        case .deviceMotion: return "move.3d"
        case .magnetometer: return "safari"
        case .location: return "location"
        case .altitude: return "mountain.2"
        case .steps: return "figure.walk"
        case .proximity: return "iphone.radiowaves.left.and.right"
        }
    }
    var requestedHz: Double? {
        switch self {
        case .accelerometer, .gyroscope, .deviceMotion: return 100
        case .magnetometer: return 25
        default: return nil
        }
    }
    var legacyRequestedHz: Double? {
        switch self {
        case .accelerometer, .gyroscope, .deviceMotion: return 50
        case .magnetometer: return 25
        default: return nil
        }
    }
    var detail: String {
        switch self {
        case .accelerometer: return "Acceleration including gravity · g"
        case .gyroscope: return "Angular velocity · rad/s"
        case .deviceMotion: return "Orientation, gravity and user acceleration"
        case .magnetometer: return "Uncalibrated magnetic field · µT"
        case .location: return "Coordinates and accuracy · requires permission"
        case .altitude: return "Relative height and pressure · m, kPa"
        case .steps: return "Cumulative count within each collector run"
        case .proximity: return "Near/far changes; may blank the display"
        }
    }
    var fields: [String] {
        switch self {
        case .accelerometer: return ["x_g", "y_g", "z_g"]
        case .gyroscope: return ["x_rad_s", "y_rad_s", "z_rad_s"]
        case .deviceMotion:
            return ["quaternion_x", "quaternion_y", "quaternion_z", "quaternion_w",
                    "gravity_x_g", "gravity_y_g", "gravity_z_g",
                    "user_acceleration_x_g", "user_acceleration_y_g", "user_acceleration_z_g",
                    "rotation_x_rad_s", "rotation_y_rad_s", "rotation_z_rad_s"]
        case .magnetometer: return ["x_microtesla", "y_microtesla", "z_microtesla"]
        case .location:
            return ["latitude_deg", "longitude_deg", "altitude_m", "horizontal_accuracy_m",
                    "vertical_accuracy_m", "speed_m_s", "course_deg"]
        case .altitude: return ["relative_altitude_m", "pressure_kpa"]
        case .steps: return ["run_cumulative_steps"]
        case .proximity: return ["near"]
        }
    }
    var header: String {
        (["sequence", "elapsed_s", "utc_epoch_s", "received_elapsed_s", "collector_run"] + fields)
            .joined(separator: ",") + "\n"
    }
    var legacyHeader: String {
        let columns = self == .steps ? ["cumulative_steps"] : fields
        return (["sequence", "source_time_s", "elapsed_s", "utc_epoch_s"] + columns)
            .joined(separator: ",") + "\n"
    }
    var portableLegacyHeader: String {
        legacyHeader.replacingOccurrences(of: "source_time_s,", with: "")
    }
}

enum SessionState: String, Codable, Sendable {
    case recording, finalizing, localComplete, interrupted, incomplete, recovered
    var title: String {
        switch self {
        case .recording: return "Recording"
        case .finalizing: return "Finalizing"
        case .localComplete: return "Saved"
        case .interrupted: return "Recovery needed"
        case .incomplete: return "Incomplete"
        case .recovered: return "Recovered"
        }
    }
    var recoverable: Bool { self == .interrupted || self == .incomplete }
    var exportable: Bool { self == .localComplete || self == .recovered }
}

struct SessionEvent: Codable, Sendable {
    var time: Date
    var kind: String
    var detail: String
    var elapsedSeconds: Double? = nil
    var sensor: Sensor? = nil
    var count: Int? = nil
    var severity: String? = nil
    var isWarning: Bool {
        severity == "warning" || ["SAMPLES_DROPPED", "SENSOR_ERROR", "WRITE_FAILED",
            "RECORDING_ABORTED", "UNCLEAN_EXIT", "PERMISSION_DENIED"].contains(kind)
    }
}

struct FileRecord: Codable, Identifiable, Sendable {
    var path: String
    var sensor: Sensor
    var samples: Int
    var bytes: Int64
    var sha256: String
    var id: String { path }
}

struct EvidenceFile: Codable, Sendable {
    var path: String
    var bytes: Int64
    var sha256: String
}

struct StreamSummary: Codable, Identifiable, Sendable {
    var sensor: Sensor
    // Persist the rate so upgrading the app cannot relabel old 50 Hz data.
    var requestedRateHz: Double? = nil
    var samples = 0
    var firstElapsed: Double? = nil
    var lastElapsed: Double? = nil
    var lastSequence: Double? = nil
    var largestGapSeconds: Double = 0
    var gapsOverThreshold = 0
    var coveredSeconds: Double = 0
    var lastValue: Double? = nil
    var id: String { sensor.rawValue }
    var averageHz: Double? {
        guard samples > 1, let first = firstElapsed, let last = lastElapsed, last > first else { return nil }
        return Double(samples - 1) / (last - first)
    }
    mutating func observe(sequence: Double, elapsed: Double, value: Double?) {
        if let last = lastElapsed {
            let gap = max(0, elapsed - last)
            largestGapSeconds = max(largestGapSeconds, gap)
            if let hz = requestedRateHz ?? sensor.legacyRequestedHz {
                coveredSeconds += min(gap, 1 / hz)
                if gap > 2.5 / hz { gapsOverThreshold += 1 }
            }
        }
        if firstElapsed == nil { firstElapsed = elapsed }
        lastElapsed = elapsed
        lastSequence = sequence
        lastValue = value
        samples += 1
    }
}

struct ResearchSession: Codable, Identifiable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var experiment: String
    var participant: String
    var notes: String
    var startedAt: Date
    var endedAt: Date?
    var lastCheckpoint: Date
    // Legacy field is read for compatibility. New recordings do not persist device uptime.
    var clockAnchorUptime: Double? = nil
    var device: String
    var osVersion: String
    var appVersion: String
    var selected: [Sensor]
    var available: [Sensor]
    var state: SessionState
    var files: [FileRecord] = []
    var events: [SessionEvent] = []
    var recovered = false
    var protocolCode: String? = nil
    var durationSeconds: Double? = nil
    var plannedSeconds: Double? = nil
    var summaries: [StreamSummary]? = nil
    var evidence: [EvidenceFile]? = nil
    var formatNotes: [String: String]? = nil
    var externalFiles: [ExternalFileRecord]? = nil
    var totalSamples: Int { files.reduce(0) { $0 + $1.samples } }
    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.bytes } + (externalFiles ?? []).reduce(0) { $0 + $1.bytes }
    }
    var duration: Double { durationSeconds ?? max(0, (endedAt ?? lastCheckpoint).timeIntervalSince(startedAt)) }
    var warningCount: Int { events.filter(\.isWarning).count }
    var needsReview: Bool {
        recovered || warningCount > 0 || selected.contains { count($0) == 0 }
            || events.contains { $0.kind == "INTERRUPTION_START" }
    }
    func count(_ sensor: Sensor) -> Int {
        files.filter { $0.sensor == sensor }.reduce(0) { $0 + $1.samples }
    }
    func summary(_ sensor: Sensor) -> StreamSummary? { summaries?.first { $0.sensor == sensor } }
    func coverage(_ sensor: Sensor) -> Double? {
        guard sensor.requestedHz != nil, duration > 0, let summary = summary(sensor) else { return nil }
        return min(1, summary.coveredSeconds / duration)
    }
}

struct RecorderError: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

enum ManifestCodec {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO date")
        }
        return decoder
    }
}

struct SampleRow: Sendable {
    var sensor: Sensor
    var sequence: Int
    var elapsed: Double
    var received: Double
    var run: Int
    var values: [Double]
    var epoch: Double
    var csv: String {
        ([Double(sequence), elapsed, epoch, received, Double(run)] + values)
            .map { String($0) }.joined(separator: ",") + "\n"
    }
}

/// Every callback is tagged with a collector generation. Stop invalidates that
/// generation before invoking framework stop methods, rejecting late callbacks.
final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    let anchorDate: Date
    private let anchorUptime: Double
    private let capacity: Int
    private var generation = 0
    private var collecting = false
    private var sealed = false
    private var runStart: Double = 0
    private var rows: [SampleRow] = []
    private var events: [SessionEvent] = []
    private var diagnostics: [String: SessionEvent] = [:]
    private var sequences: [Sensor: Int] = [:]
    private var lastTimes: [Sensor: Double] = [:]
    
    // Retains only the newest accepted sample for each sensor.
    // Preview reads never remove data from the recording buffer.
    private var previewRows: [Sensor: SampleRow] = [:]

    func preview() -> [Sensor: SampleRow] {
        lock.lock()
        defer { lock.unlock() }
        return previewRows
    }

    init(date: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime, capacity: Int = 20_000) {
        anchorDate = date; anchorUptime = uptime; self.capacity = capacity
    }
    func elapsedNow() -> Double { max(0, ProcessInfo.processInfo.systemUptime - anchorUptime) }
    func elapsed(for date: Date) -> Double { date.timeIntervalSince(anchorDate) }
    func elapsed(uptime: Double) -> Double { uptime - anchorUptime }
    func startRun() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1; collecting = !sealed; runStart = elapsedNow()
        return generation
    }
    func pause() { lock.lock(); collecting = false; lock.unlock() }
    func seal() { lock.lock(); sealed = true; collecting = false; lock.unlock() }
    func append(_ sensor: Sensor, run: Int, elapsed: Double, received: Double,
                values: [Double]) {
        lock.lock(); defer { lock.unlock() }
        guard !sealed, collecting, run == generation else { return }
        guard values.count == sensor.fields.count, values.allSatisfy({ $0.isFinite }),
              elapsed.isFinite, received.isFinite else {
            diagnostic("INVALID_SAMPLE", sensor, "Rejected invalid values or column count.", "warning")
            return
        }
        guard elapsed >= 0, elapsed >= runStart - 0.1 else {
            diagnostic("PRE_RUN_SAMPLE", sensor, "Excluded a measurement preceding this collector run.", "info")
            return
        }
        guard elapsed <= received + 0.25 else {
            diagnostic("FUTURE_TIMESTAMP", sensor, "Measurement time exceeds arrival time; check device clock.", "warning")
            return
        }
        guard elapsed >= lastTimes[sensor, default: -1] else {
            diagnostic("OUT_OF_ORDER_SAMPLE", sensor, "Rejected a measurement older than the last accepted sample.", "warning")
            return
        }
        guard rows.count < capacity else {
            diagnostic("BUFFER_OVERFLOW", sensor, "The bounded callback buffer was full.", "warning")
            return
        }
        let sequence = sequences[sensor, default: 0] + 1
        sequences[sensor] = sequence; lastTimes[sensor] = elapsed
        rows.append(SampleRow(sensor: sensor, sequence: sequence, elapsed: elapsed,
                              received: received, run: run, values: values,
                              epoch: anchorDate.timeIntervalSince1970 + elapsed))
            
        previewRows[sensor] = rows.last
    }
    private func diagnostic(_ kind: String, _ sensor: Sensor, _ detail: String, _ severity: String) {
        let key = kind + sensor.rawValue
        if var existing = diagnostics[key] {
            existing.count = (existing.count ?? 1) + 1; diagnostics[key] = existing
        } else {
            diagnostics[key] = SessionEvent(time: Date(), kind: kind, detail: detail,
                elapsedSeconds: elapsedNow(), sensor: sensor, count: 1, severity: severity)
        }
    }
    func sensorError(_ sensor: Sensor, run: Int, message: String) {
        lock.lock(); defer { lock.unlock() }
        guard collecting, !sealed, generation == run else { return }
        diagnostic("SENSOR_ERROR", sensor, message, "warning")
    }
    func event(_ kind: String, _ detail: String, severity: String = "info") {
        lock.lock(); defer { lock.unlock() }
        guard !sealed else { return }
        if events.count < 1_000 {
            events.append(SessionEvent(time: Date(), kind: kind, detail: detail,
                                       elapsedSeconds: elapsedNow(), severity: severity))
        }
    }
    func drain() -> ([SampleRow], [SessionEvent]) {
        lock.lock(); defer { lock.unlock() }
        let result = (rows, (events + Array(diagnostics.values)).sorted { $0.time < $1.time })
        rows.removeAll(keepingCapacity: true); events.removeAll(keepingCapacity: true)
        diagnostics.removeAll(keepingCapacity: true)
        return result
    }
}

// MARK: - Bounded streaming validation

struct CSVScan {
    var record: FileRecord
    var validBytes: UInt64
    var tailBytes: Int
}

enum SessionFiles {
    static func exportName(_ title: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        let cleaned = title.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var name = ""
        for character in cleaned {
            guard name.utf8.count + String(character).utf8.count <= 160 else { break }
            name.append(character)
        }
        return name.isEmpty ? "Research recording" : name
    }
    static func safeURL(root: URL, relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RecorderError(message: "Unsafe path in session manifest.")
        }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            if FileManager.default.fileExists(atPath: url.path),
               try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw RecorderError(message: "Symbolic links are not permitted in a session.")
            }
        }
        return url
    }
    static func fingerprint(_ url: URL) throws -> (Int64, String) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(); var bytes: Int64 = 0
        while let data = try file.read(upToCount: 65_536), !data.isEmpty {
            hash.update(data: data); bytes += Int64(data.count)
        }
        return (bytes, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func scan(_ url: URL, relative: String, sensor: Sensor,
                     allowPartialTail: Bool, summary: inout StreamSummary) throws -> CSVScan {
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        var pending = Data(); var hash = SHA256(); var validBytes: UInt64 = 0
        var rowCount = 0; var headerSeen = false; var v2 = false; var portableLegacy = false
        while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let end = pending.index(after: newline)
                let data = Data(pending[..<end]); pending.removeSubrange(..<end)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw RecorderError(message: "Invalid UTF-8 in \(relative).")
                }
                if !headerSeen {
                    guard text == sensor.header || text == sensor.legacyHeader || text == sensor.portableLegacyHeader else {
                        throw RecorderError(message: "Unexpected CSV header in \(relative).")
                    }
                    v2 = text == sensor.header; headerSeen = true
                    portableLegacy = text == sensor.portableLegacyHeader
                } else {
                    let tokens = text.trimmingCharacters(in: .newlines).split(separator: ",", omittingEmptySubsequences: false)
                    let numbers = tokens.compactMap { Double($0) }
                    let expected = sensor.fields.count + (v2 ? 5 : portableLegacy ? 3 : 4)
                    guard tokens.count == expected, numbers.count == expected,
                          numbers.allSatisfy({ $0.isFinite }) else {
                        throw RecorderError(message: "Malformed numeric row in \(relative).")
                    }
                    let sequence = numbers[0]; let elapsed = numbers[v2 || portableLegacy ? 1 : 2]
                    guard sequence > 0, sequence.rounded() == sequence, elapsed >= 0,
                          summary.lastSequence.map({ sequence == $0 + 1 }) ?? true,
                          summary.lastElapsed.map({ elapsed >= $0 }) ?? true else {
                        throw RecorderError(message: "Sequence or time discontinuity in \(relative).")
                    }
                    if v2 {
                        guard numbers[3] >= 0, numbers[4] >= 1,
                              numbers[4].rounded() == numbers[4] else {
                            throw RecorderError(message: "Invalid arrival time or collector run in \(relative).")
                        }
                    }
                    summary.observe(sequence: sequence, elapsed: elapsed, value: numbers.last)
                    rowCount += 1
                }
                validBytes += UInt64(data.count); hash.update(data: data)
            }
            guard pending.count <= 16_384 else {
                throw RecorderError(message: "Oversized CSV row in \(relative).")
            }
        }
        guard headerSeen, allowPartialTail || pending.isEmpty else {
            throw RecorderError(message: "Incomplete CSV data in \(relative).")
        }
        return CSVScan(record: FileRecord(path: relative, sensor: sensor, samples: rowCount,
            bytes: Int64(validBytes), sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()),
            validBytes: validBytes, tailBytes: pending.count)
    }
}

struct CatalogResult: Sendable { var sessions: [ResearchSession]; var issues: [String] }

struct StorageSnapshot: Sendable {
    let available: Int64
    let total: Int64?
    let includesReclaimableSpace: Bool
}

// MARK: - Local store (all file work is off the main actor)

actor LocalStore {
    let root: URL
    var current: ResearchSession?
    private var indexes: [String: Int] = [:]
    static let minimumFreeBytes: Int64 = 50 * 1024 * 1024
    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: root.path
        )
        #endif
        // Research recordings are exported deliberately, not silently backed up to iCloud.
        var directory = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        // Remove abandoned temporary exports from a previous process, never recordings.
        let oldExports = FileManager.default.temporaryDirectory.appendingPathComponent("ResearchExports")
        if FileManager.default.fileExists(atPath: oldExports.path) { try? FileManager.default.removeItem(at: oldExports) }
    }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func manifest(_ id: UUID) -> URL { folder(id).appendingPathComponent("manifest.json") }
    func persist(_ session: ResearchSession) throws {
        try ManifestCodec.encoder().encode(session).write(to: manifest(session.id), options: .atomic)
    }
    func load(_ id: UUID) throws -> ResearchSession {
        let url = try SessionFiles.safeURL(root: root, relative: "\(id.uuidString)/manifest.json")
        let session = try ManifestCodec.decoder().decode(ResearchSession.self, from: Data(contentsOf: url))
        guard session.id == id, [1, 2, 3].contains(session.schemaVersion),
              Set(session.files.map(\.path)).count == session.files.count else {
            throw RecorderError(message: "Incompatible or inconsistent manifest.")
        }
        return session
    }
    func freeBytes() throws -> Int64 {
        try storageSnapshot().available
    }
    func storageSnapshot() throws -> StorageSnapshot {
        let resource = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let capacity: Int64?
        if let value = resource?.volumeTotalCapacity { capacity = Int64(value) } else { capacity = nil }
        if let available = resource?.volumeAvailableCapacityForImportantUsage, available >= 0 {
            return StorageSnapshot(available: available, total: capacity, includesReclaimableSpace: true)
        }
        let values = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard let free = (values[.systemFreeSize] as? NSNumber)?.int64Value else {
            throw RecorderError(message: "iOS could not report available storage. Try again after reopening the app.")
        }
        return StorageSnapshot(available: free, total: (values[.systemSize] as? NSNumber)?.int64Value, includesReclaimableSpace: false)
    }
    func catalog() -> CatalogResult {
        var result: [ResearchSession] = []; var issues: [String] = []
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            for url in urls {
                guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
                do {
                    var session = try load(id)
                    if id != current?.id, session.state.exportable {
                        let listed = Set((session.externalFiles ?? []).map(\.path))
                        let orphan = try allFiles(id).contains { $0.hasPrefix("external/") && !listed.contains($0) }
                        if orphan {
                            session.state = .incomplete
                            session.events.append(SessionEvent(time: Date(), kind: "EXTERNAL_IMPORT_INTERRUPTED",
                                detail: "Unlisted external bytes were found. Recovery will retain these as evidence.", severity: "warning"))
                            try persist(session)
                        }
                    }
                    if id != current?.id && [.recording, .finalizing].contains(session.state) {
                        session.state = .interrupted
                        session.events.append(SessionEvent(time: Date(), kind: "UNCLEAN_EXIT",
                            detail: "The recording did not finalize. Its exact end time is unknown.", severity: "warning"))
                        try persist(session)
                    }
                    result.append(session)
                } catch { issues.append("\(id.uuidString.prefix(8)): \(error.localizedDescription)") }
            }
        } catch { issues.append(error.localizedDescription) }
        return CatalogResult(sessions: result.sorted { $0.startedAt > $1.startedAt }, issues: issues)
    }
    func begin(experiment: String, participant: String, notes: String, protocolCode: String,
               selected: [Sensor], available: [Sensor], device: String, os: String, app: String,
               plannedSeconds: Double?, buffer: SampleBuffer) throws -> ResearchSession {
        guard current == nil, !experiment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !selected.isEmpty, Set(selected).count == selected.count,
              selected.allSatisfy(available.contains) else {
            throw RecorderError(message: "Check the experiment name and selected sensors.")
        }
        guard try freeBytes() >= Self.minimumFreeBytes * 2 else {
            throw RecorderError(message: "At least 100 MB of free storage is required.")
        }
        let id = UUID(); try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: false)
        let session = ResearchSession(schemaVersion: 3, id: id, experiment: experiment,
            participant: participant, notes: notes, startedAt: buffer.anchorDate, endedAt: nil,
            lastCheckpoint: buffer.anchorDate, device: device, osVersion: os, appVersion: app,
            selected: selected, available: available, state: .recording, protocolCode: protocolCode,
            durationSeconds: 0, plannedSeconds: plannedSeconds,
            summaries: selected.map { StreamSummary(sensor: $0, requestedRateHz: $0.requestedHz) }, evidence: [], formatNotes: [
                "clock": "elapsed_s is measurement time relative to session start; utc_epoch_s uses the same anchor. received_elapsed_s is callback arrival time. Raw device uptime is not exported.",
                "steps": "run_cumulative_steps counts steps within collector_run. Do not add rows; use the maximum count per run. Historical reconciliation is not performed.",
                "altitude": "relative_altitude_m resets at each collector_run.",
                "coverage": "For requested-rate sensors, sum min(inter-sample interval, requested period), divided by session duration. This conservative observed-time estimate includes pauses in the denominator and is not a guarantee of physical sample completeness.",
                "rates": "accelerometer=100 Hz; gyroscope=100 Hz; deviceMotion=100 Hz; magnetometer=25 Hz requested. Other sensors are event-driven. External rates are determined by the device.",
                "referenceFrame": "Device motion xArbitraryZVertical. Units are in column names. Magnetometer is uncalibrated. Negative location accuracy/speed/course values are unavailable sentinels."
            ])
        try persist(session); current = session; indexes = [:]
        return session
    }
    /// Drain and write under the same actor operation. No detached drain can race finalization.
    func checkpoint(id: UUID, buffer: SampleBuffer) throws -> ResearchSession? {
        guard current?.id == id else { return nil }
        guard try freeBytes() >= Self.minimumFreeBytes else {
            throw RecorderError(message: "Free storage is below the recording reserve.")
        }
        let (rows, events) = buffer.drain()
        guard var session = current else { return nil }
        session.events.append(contentsOf: events)
        do {
            let grouped = Dictionary(grouping: rows) { row in
                "\(row.sensor.rawValue)/" + String(format: "segment_%06d.csv", Int(row.elapsed / 60) + 1)
            }
            for path in grouped.keys.sorted() {
                guard let batch = grouped[path], let first = batch.first else { continue }
                let url = try SessionFiles.safeURL(root: folder(id), relative: path)
                if indexes[path] == nil {
                    guard !FileManager.default.fileExists(atPath: url.path) else {
                        throw RecorderError(message: "An unexpected segment already exists.")
                    }
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(first.sensor.header.utf8).write(to: url, options: .withoutOverwriting)
                    indexes[path] = session.files.count
                    session.files.append(FileRecord(path: path, sensor: first.sensor, samples: 0,
                                                     bytes: Int64(first.sensor.header.utf8.count), sha256: ""))
                }
                guard let index = indexes[path] else { throw RecorderError(message: "Missing writer index.") }
                let data = Data(batch.map(\.csv).joined().utf8)
                let handle = try FileHandle(forWritingTo: url)
                do {
                    try handle.seekToEnd(); try handle.write(contentsOf: data)
                    try handle.synchronize(); try handle.close()
                } catch { try? handle.close(); throw error }
                session.files[index].samples += batch.count; session.files[index].bytes += Int64(data.count)
                if let summaryIndex = session.summaries?.firstIndex(where: { $0.sensor == first.sensor }) {
                    for row in batch {
                        session.summaries?[summaryIndex].observe(sequence: Double(row.sequence), elapsed: row.elapsed, value: row.values.last)
                    }
                }
            }
            session.lastCheckpoint = Date(); session.durationSeconds = buffer.elapsedNow()
            current = session; try persist(session)
            return session
        } catch {
            session.state = .incomplete
            session.events.append(SessionEvent(time: Date(), kind: "WRITE_FAILED",
                detail: "File inventory requires recovery: \(error.localizedDescription)",
                elapsedSeconds: buffer.elapsedNow(), severity: "warning"))
            current = session; try? persist(session); throw error
        }
    }
    private func csvPaths(_ id: UUID) throws -> [(Sensor, String)] {
        var result: [(Sensor, String)] = []
        for sensor in Sensor.allCases {
            let directory = try SessionFiles.safeURL(root: folder(id), relative: sensor.rawValue)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "csv" {
                result.append((sensor, "\(sensor.rawValue)/\(file.lastPathComponent)"))
            }
        }
        return result
    }
    private func scanFiles(_ id: UUID, repair: Bool) throws -> ([FileRecord], [StreamSummary]) {
        var records: [FileRecord] = []; var summaries: [Sensor: StreamSummary] = [:]
        let saved = try load(id)
        for (sensor, path) in try csvPaths(id) {
            let url = try SessionFiles.safeURL(root: folder(id), relative: path)
            var summary = summaries[sensor] ?? StreamSummary(sensor: sensor,
                requestedRateHz: saved.summary(sensor)?.requestedRateHz ?? sensor.legacyRequestedHz)
            let scan = try SessionFiles.scan(url, relative: path, sensor: sensor, allowPartialTail: repair, summary: &summary)
            if scan.tailBytes > 0 {
                // Preserve the entire unmodified original before repairing an unfinished CSV.
                let backup = try SessionFiles.safeURL(root: folder(id), relative: "recovery-originals/\(UUID().uuidString)/\(path)")
                try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: backup)
                let handle = try FileHandle(forWritingTo: url)
                do { try handle.truncate(atOffset: scan.validBytes); try handle.synchronize(); try handle.close() }
                catch { try? handle.close(); throw error }
            }
            summaries[sensor] = summary; records.append(scan.record)
        }
        return (records, Sensor.allCases.compactMap { summaries[$0] })
    }
    func finish(id: UUID, buffer: SampleBuffer, endElapsed: Double) throws -> ResearchSession {
        guard current?.id == id else { throw RecorderError(message: "No matching recording is open.") }
        buffer.seal()
        _ = try checkpoint(id: id, buffer: buffer)
        guard var session = current else { throw RecorderError(message: "Recording state is unavailable.") }
        guard session.state != .incomplete else { throw RecorderError(message: "This session requires recovery.") }
        session.state = .finalizing; current = session; try persist(session)
        let (records, summaries) = try scanFiles(id, repair: false)
        session.files = records; session.summaries = summaries
        session.durationSeconds = endElapsed
        session.endedAt = session.startedAt.addingTimeInterval(endElapsed)
        session.lastCheckpoint = Date()
        session.state = session.totalSamples > 0 || !(session.externalFiles ?? []).isEmpty ? .localComplete : .incomplete
        for sensor in session.selected where session.count(sensor) == 0 {
            session.events.append(SessionEvent(time: Date(), kind: "NO_SAMPLES",
                detail: "No samples were saved for \(sensor.title).", elapsedSeconds: endElapsed,
                sensor: sensor, severity: "warning"))
        }
        session.events.append(SessionEvent(time: Date(), kind: "LOCAL_FINALIZATION",
            detail: "Closed files validated and fingerprinted. Acquisition ended before this finalization.", elapsedSeconds: endElapsed))
        try persist(session); current = nil; indexes = [:]
        return session
    }
    func fail(id: UUID, message: String) throws {
        guard var session = current, session.id == id else { return }
        defer { current = nil; indexes = [:] }
        session.state = .incomplete
        session.events.append(SessionEvent(time: Date(), kind: "RECORDING_ABORTED", detail: message, severity: "warning"))
        try persist(session)
    }
    func recover(_ id: UUID) throws -> ResearchSession {
        guard current == nil else { throw RecorderError(message: "Finish the active recording before recovery.") }
        var session = try load(id)
        guard session.state.recoverable else { throw RecorderError(message: "This session does not need recovery.") }
        let backupRoot = folder(id).appendingPathComponent("recovery-originals")
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: manifest(id), to: backupRoot.appendingPathComponent("manifest-\(UUID().uuidString).json"))
        // A crash between an external-copy completion and the atomic manifest
        // commit can leave unlisted bytes. Preserve those as recovery evidence.
        let listedExternal = Set((session.externalFiles ?? []).map(\.path))
        for path in try allFiles(id) where path.hasPrefix("external/") && !listedExternal.contains(path) {
            let original = try SessionFiles.safeURL(root: folder(id), relative: path)
            let backup = try SessionFiles.safeURL(root: folder(id), relative: "recovery-originals/orphan-\(UUID().uuidString)/\(path)")
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: original, to: backup)
        }
        let (records, summaries) = try scanFiles(id, repair: true)
        session.files = records; session.summaries = summaries
        session.state = .recovered; session.recovered = true; session.endedAt = nil
        session.events.append(SessionEvent(time: Date(), kind: "RECOVERED",
            detail: "Available CSV rows recovered. Original manifests and any repaired files are preserved. Exact recording end and completeness remain unknown.", severity: "warning"))
        var evidence: [EvidenceFile] = []
        for relative in try allFiles(id).filter({ $0.hasPrefix("recovery-originals/") }) {
            let (bytes, hash) = try SessionFiles.fingerprint(SessionFiles.safeURL(root: folder(id), relative: relative))
            evidence.append(EvidenceFile(path: relative, bytes: bytes, sha256: hash))
        }
        session.evidence = evidence
        try persist(session)
        return session
    }
    private func allFiles(_ id: UUID) throws -> Set<String> {
        let base = folder(id).resolvingSymlinksInPath().standardizedFileURL
        var result = Set<String>(); var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: base,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw RecorderError(message: "The session directory cannot be enumerated.")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw RecorderError(message: "Unexpected symbolic link.") }
            if values.isRegularFile == true {
                let components = url.standardizedFileURL.pathComponents
                let rootComponents = base.pathComponents
                guard components.starts(with: rootComponents) else { throw RecorderError(message: "A session file is outside its directory.") }
                result.insert(components.dropFirst(rootComponents.count).joined(separator: "/"))
            }
        }
        if let error = enumerationError { throw error }
        return result
    }
    func verify(_ id: UUID) throws {
        guard current?.id != id else { throw RecorderError(message: "Finish recording before verification.") }
        let session = try load(id)
        guard session.state.exportable else { throw RecorderError(message: "Recover this session before exporting.") }
        let expectedPaths = session.files.map(\.path) + (session.evidence ?? []).map(\.path)
            + (session.externalFiles ?? []).map(\.path) + ["manifest.json"]
        guard Set(expectedPaths).count == expectedPaths.count,
              try allFiles(id) == Set(expectedPaths) else {
            throw RecorderError(message: "The session contains missing or unlisted files.")
        }
        let (actual, _) = try scanFiles(id, repair: false)
        guard actual.count == session.files.count else { throw RecorderError(message: "CSV inventory mismatch.") }
        for file in session.files {
            guard let found = actual.first(where: { $0.path == file.path }),
                  found.sensor == file.sensor, found.samples == file.samples,
                  found.bytes == file.bytes, found.sha256 == file.sha256, !file.sha256.isEmpty else {
                throw RecorderError(message: "Integrity mismatch: \(file.path)")
            }
        }
        for file in session.evidence ?? [] {
            let (bytes, hash) = try SessionFiles.fingerprint(SessionFiles.safeURL(root: folder(id), relative: file.path))
            guard bytes == file.bytes, hash == file.sha256 else { throw RecorderError(message: "Recovery evidence mismatch.") }
        }
        for file in session.externalFiles ?? [] {
            guard file.path.hasPrefix("external/") else { throw RecorderError(message: "Invalid external file path.") }
            let (bytes, hash) = try SessionFiles.fingerprint(SessionFiles.safeURL(root: folder(id), relative: file.path))
            guard bytes == file.bytes, hash == file.sha256 else {
                throw RecorderError(message: "External file integrity mismatch: \(file.originalName)")
            }
        }
    }
    func export(_ id: UUID) throws -> URL {
        guard current == nil else { throw RecorderError(message: "Finish recording before exporting.") }
        do { try verify(id) }
        catch { throw RecorderError(message: "Session verification failed: \(error.localizedDescription) The original files remain on this device.") }
        let session = try load(id)
        let total = session.totalBytes + (session.evidence ?? []).reduce(Int64(0)) { $0 + $1.bytes }
        guard try freeBytes() > total * 3 + Self.minimumFreeBytes else {
            throw RecorderError(message: "There is not enough free space to prepare the export.")
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ResearchExports")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let exportFolder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: false)
        let output = exportFolder.appendingPathComponent(SessionFiles.exportName(session.experiment) + ".zip")
        let staging = base.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var source = folder(id)
        if session.schemaVersion == 1 {
            // Required-reason API rules prohibit exporting raw system uptime.
            // Make a separately fingerprinted portable copy; never rewrite originals.
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var portable = session
            portable.clockAnchorUptime = nil; portable.evidence = []
            portable.formatNotes = (portable.formatNotes ?? [:]).merging([
                "exportTransformation": "Portable legacy export: source_time_s and clockAnchorUptime omitted. Working CSV values otherwise retained; fingerprints recalculated. Original session and any recovery-originals remain unchanged on device; recovery-originals are not included in this portable export."
            ]) { _, new in new }
            for index in portable.files.indices {
                let record = portable.files[index]
                let original = try SessionFiles.safeURL(root: folder(id), relative: record.path)
                let destination = try SessionFiles.safeURL(root: staging, relative: record.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.portableLegacyCSV(original, destination: destination, sensor: record.sensor)
                let (bytes, hash) = try SessionFiles.fingerprint(destination)
                portable.files[index].bytes = bytes; portable.files[index].sha256 = hash
            }
            try ManifestCodec.encoder().encode(portable).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            source = staging
        }
        let paths = session.files.map(\.path) + (session.schemaVersion == 1 ? [] : (session.evidence ?? []).map(\.path))
            + (session.externalFiles ?? []).map(\.path) + ["manifest.json"]
        do { try SessionArchive.write(root: source, paths: paths, output: output) }
        catch { throw RecorderError(message: "ZIP creation failed: \(error.localizedDescription) Your session remains saved. Check available storage and retry.") }
        return output
    }
    private static func portableLegacyCSV(_ source: URL, destination: URL, sensor: Sensor) throws {
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        try Data().write(to: destination, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
        var pending = Data(); var first = true; var removeSource = true
        while let data = try input.read(upToCount: 65_536), !data.isEmpty {
            pending.append(data)
            while let index = pending.firstIndex(of: 10) {
                let end = pending.index(after: index)
                guard let line = String(data: pending[..<end], encoding: .utf8) else { throw RecorderError(message: "Invalid legacy CSV encoding.") }
                pending.removeSubrange(..<end)
                if first {
                    guard line == sensor.legacyHeader || line == sensor.portableLegacyHeader else { throw RecorderError(message: "Unexpected legacy header.") }
                    removeSource = line == sensor.legacyHeader; first = false
                    try output.write(contentsOf: Data(sensor.portableLegacyHeader.utf8))
                } else {
                    var columns = line.trimmingCharacters(in: .newlines).components(separatedBy: ",")
                    if removeSource { columns.remove(at: 1) }
                    try output.write(contentsOf: Data((columns.joined(separator: ",") + "\n").utf8))
                }
            }
        }
        guard pending.isEmpty, !first else { throw RecorderError(message: "Incomplete legacy CSV.") }
        try output.synchronize()
    }
    func delete(_ id: UUID) throws {
        guard current == nil else { throw RecorderError(message: "Finish recording before deleting sessions.") }
        _ = try load(id)
        try FileManager.default.removeItem(at: folder(id))
    }
    func cleanExport(_ url: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ResearchExports").standardizedFileURL
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.deletingLastPathComponent() == base,
              UUID(uuidString: parent.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: parent)
    }
}
