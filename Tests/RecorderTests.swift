import XCTest
@testable import SCOPECaptureCore

final class RecorderTests: XCTestCase {
    func testMotionRequests100HzWithoutChangingEventDrivenSensors() {
        XCTAssertEqual(Sensor.accelerometer.requestedHz, 100)
        XCTAssertEqual(Sensor.gyroscope.requestedHz, 100)
        XCTAssertEqual(Sensor.deviceMotion.requestedHz, 100)
        XCTAssertNil(Sensor.proximity.requestedHz)
        XCTAssertEqual(Sensor.accelerometer.legacyRequestedHz, 50)
    }
    func testRenamingChangesExportNameAndPreservesRecordingID() async throws {
        let root = try temporary(), store = try LocalStore(root: root), buffer = SampleBuffer()
        let session = try await begin(store, buffer: buffer)
        append(buffer, run: buffer.startRun())
        _ = try await store.finish(id: session.id, buffer: buffer, endElapsed: buffer.elapsedNow())
        try await store.rename(session.id, title: "Chest Trial 01")
        let zip = try await store.export(session.id)
        XCTAssertEqual(zip.lastPathComponent, "Chest Trial 01.zip")
        let catalog = await store.catalog()
        XCTAssertEqual(catalog.sessions.first?.id, session.id)
        try await store.verify(session.id)
        await store.cleanExport(zip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path))
    }
    func testRateIsPersistedAndOldSummariesKeep50HzMeaning() async throws {
        let store = try LocalStore(root: temporary()), buffer = SampleBuffer()
        let session = try await begin(store, buffer: buffer)
        XCTAssertEqual(session.summary(.accelerometer)?.requestedRateHz, 100)
        let old = Data("{\"sensor\":\"accelerometer\",\"samples\":0,\"largestGapSeconds\":0,\"gapsOverThreshold\":0,\"coveredSeconds\":0}".utf8)
        var summary = try JSONDecoder().decode(StreamSummary.self, from: old)
        summary.observe(sequence: 1, elapsed: 0, value: 0)
        summary.observe(sequence: 2, elapsed: 0.02, value: 0)
        XCTAssertEqual(summary.coveredSeconds, 0.02, accuracy: 0.000001)
    }
    func testExternalBinaryFilesRemainExactAndTamperingIsRejected() async throws {
        let root = try temporary(), incoming = try temporary(), store = try LocalStore(root: root)
        let data = Data([0, 255, 13, 10, 0, 128, 1, 2, 254])
        let original = incoming.appendingPathComponent("原始.bin")
        try data.write(to: original)
        let profile = ExternalDeviceProfile(name: "Lab logger", manufacturer: "Lab", model: "Test", notes: "")
        let session = try await store.createExternalSession(title: "Binary Trial", device: "Test", os: "Test", app: "Test")
        try await store.attachExternalFiles([original, original], to: session.id, device: profile)
        let catalog = await store.catalog()
        let saved = try XCTUnwrap(catalog.sessions.first)
        XCTAssertEqual(saved.externalFiles?.count, 2)
        for file in saved.externalFiles ?? [] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(saved.id.uuidString).appendingPathComponent(file.path)), data)
        }
        try await store.verify(saved.id)
        let record = try XCTUnwrap(saved.externalFiles?.first)
        try Data([7]).write(to: root.appendingPathComponent(saved.id.uuidString).appendingPathComponent(record.path))
        do { try await store.verify(saved.id); XCTFail("Modified binary file must fail verification") } catch {}
    }
    func testExternalImportRollsBackWhenAnySourceIsInvalid() async throws {
        let root = try temporary(), incoming = try temporary(), store = try LocalStore(root: root)
        let file = incoming.appendingPathComponent("test.raw")
        try Data([0, 1, 2]).write(to: file)
        let profile = ExternalDeviceProfile(name: "Logger", manufacturer: "", model: "", notes: "")
        let session = try await store.createExternalSession(title: "Rollback", device: "Test", os: "Test", app: "Test")
        do {
            try await store.attachExternalFiles([file, incoming.appendingPathComponent("missing.raw")], to: session.id, device: profile)
            XCTFail("Missing source must fail the transaction")
        } catch {}
        let catalog = await store.catalog()
        XCTAssertTrue((catalog.sessions.first?.externalFiles ?? []).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data([0, 1, 2]))
    }
    func testExportNameCannotCreateAPath() {
        XCTAssertEqual(SessionFiles.exportName("../Chest:Trial/01"), "_Chest_Trial_01")
        XCTAssertEqual(SessionFiles.exportName("..."), "Research recording")
        XCTAssertLessThanOrEqual(SessionFiles.exportName(String(repeating: "界", count: 120)).utf8.count, 160)
    }
    func testZIP64CanBeExtractedBySystemReader() throws {
        #if os(macOS)
        let root = try temporary()
        let files: [String: Data] = [
            "manifest.json": Data("{\"fixture\":true}".utf8),
            "accelerometer/segment_000001.csv": Data("123456789".utf8),
            "empty.csv": Data(),
            "notes/étude.txt": Data("Research export".utf8)
        ]
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let output = root.appendingPathComponent("session.zip")
        try SessionArchive.write(root: root, paths: Array(files.keys), output: output)
        let extracted = root.appendingPathComponent("extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", output.path, extracted.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        for (path, data) in files { XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(path)), data) }
        #else
        throw XCTSkip("The system ZIP reader test requires macOS ditto.")
        #endif
    }
    func testArchiveFailureRemovesPartialZIP() throws {
        let root = try temporary()
        let output = root.appendingPathComponent("failed.zip")
        XCTAssertThrowsError(try SessionArchive.write(root: root, paths: ["missing.csv"], output: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testStoreCanonicalizesDirectoryAliases() async throws {
        let parent = try temporary()
        let actual = parent.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let store = try LocalStore(root: alias), buffer = SampleBuffer()
        let session = try await begin(store, buffer: buffer)
        append(buffer, run: buffer.startRun())
        _ = try await store.finish(id: session.id, buffer: buffer, endElapsed: buffer.elapsedNow())
        try await store.verify(session.id)
        let zip = try await store.export(session.id)
        let header = try FileHandle(forReadingFrom: zip)
        XCTAssertEqual(try header.read(upToCount: 4), Data([0x50, 0x4b, 0x03, 0x04]))
        try header.close()
        await store.cleanExport(zip)
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func begin(_ store: LocalStore, buffer: SampleBuffer) async throws -> ResearchSession {
        try await store.begin(experiment: "Fixture", participant: "P001", notes: "", protocolCode: "TEST",
            selected: [.accelerometer], available: [.accelerometer], device: "Test device", os: "Test OS",
            app: "Test", plannedSeconds: nil, buffer: buffer)
    }
    private func append(_ buffer: SampleBuffer, run: Int, value: Double = 1) {
        let now = buffer.elapsedNow()
        buffer.append(.accelerometer, run: run, elapsed: now, received: now, values: [value, 0, -1])
    }
    func testLateCallbacksAndSealedBufferAreRejected() {
        let buffer = SampleBuffer()
        let first = buffer.startRun(); append(buffer, run: first)
        buffer.pause(); append(buffer, run: first)
        let second = buffer.startRun(); append(buffer, run: first); append(buffer, run: second)
        buffer.seal(); append(buffer, run: second)
        let (rows, _) = buffer.drain()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.sequence), [1, 2])
        XCTAssertEqual(rows.map(\.run), [first, second])
    }
    func testOverflowAndInvalidMeasurementsAreCountedSeparately() {
        let buffer = SampleBuffer(capacity: 1)
        let run = buffer.startRun()
        append(buffer, run: run, value: .nan)
        append(buffer, run: run); append(buffer, run: run); append(buffer, run: run)
        let (rows, events) = buffer.drain()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(events.first { $0.kind == "INVALID_SAMPLE" }?.count, 1)
        XCTAssertEqual(events.first { $0.kind == "BUFFER_OVERFLOW" }?.count, 2)
    }
    func testMeasurementAndArrivalTimesRemainDistinct() {
        let buffer = SampleBuffer()
        let run = buffer.startRun()
        let measured = buffer.elapsedNow()
        buffer.append(.steps, run: run, elapsed: measured, received: measured + 2.5, values: [4])
        let row = buffer.drain().0.first
        XCTAssertEqual(row?.elapsed, measured)
        XCTAssertEqual(row?.received, measured + 2.5)
        XCTAssertEqual(row?.epoch ?? 0, buffer.anchorDate.timeIntervalSince1970 + measured, accuracy: 0.000001)
    }
    func testPathTraversalAndSymlinksAreRejected() throws {
        let root = try temporary()
        XCTAssertThrowsError(try SessionFiles.safeURL(root: root, relative: "../outside.csv"))
        XCTAssertThrowsError(try SessionFiles.safeURL(root: root, relative: "/outside.csv"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try SessionFiles.safeURL(root: root, relative: "link/file.csv"))
    }
    func testLegacyManifestAndHeaderRemainReadable() throws {
        let json = """
        {"schemaVersion":1,"id":"00000000-0000-0000-0000-000000000001","experiment":"Legacy","participant":"P001","notes":"","startedAt":"2026-01-01T00:00:00Z","endedAt":"2026-01-01T00:00:01Z","lastCheckpoint":"2026-01-01T00:00:01Z","clockAnchorUptime":100,"device":"iPhone","osVersion":"17","appVersion":"1.0","selected":["accelerometer"],"available":["accelerometer"],"state":"localComplete","files":[],"events":[],"recovered":false}
        """
        let session = try ManifestCodec.decoder().decode(ResearchSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.schemaVersion, 1); XCTAssertNil(session.summaries)
        let url = try temporary().appendingPathComponent("segment.csv")
        try Data((Sensor.accelerometer.legacyHeader + "1,100.02,0.02,1767225600.02,0,0,-1\n").utf8).write(to: url)
        var summary = StreamSummary(sensor: .accelerometer)
        let scan = try SessionFiles.scan(url, relative: "segment.csv", sensor: .accelerometer, allowPartialTail: false, summary: &summary)
        XCTAssertEqual(scan.record.samples, 1)
    }
    func testFinalizeValidatesAndDetectsLaterTampering() async throws {
        let root = try temporary(), store = try LocalStore(root: root), buffer = SampleBuffer()
        let session = try await begin(store, buffer: buffer)
        append(buffer, run: buffer.startRun())
        let saved = try await store.finish(id: session.id, buffer: buffer, endElapsed: buffer.elapsedNow())
        XCTAssertEqual(saved.state, .localComplete); XCTAssertEqual(saved.totalSamples, 1)
        try await store.verify(saved.id)
        let csv = root.appendingPathComponent(saved.id.uuidString).appendingPathComponent(try XCTUnwrap(saved.files.first).path)
        var data = try Data(contentsOf: csv); data.append(Data("broken\n".utf8)); try data.write(to: csv)
        do { try await store.verify(saved.id); XCTFail("Tampered file must not verify") } catch {}
    }
    func testRecoveryPreservesOriginalAndRemovesOnlyUnfinishedTail() async throws {
        let root = try temporary(), firstStore = try LocalStore(root: root), buffer = SampleBuffer()
        let session = try await begin(firstStore, buffer: buffer)
        append(buffer, run: buffer.startRun())
        let checkpointResult = try await firstStore.checkpoint(id: session.id, buffer: buffer)
        let checkpoint = try XCTUnwrap(checkpointResult)
        let csv = root.appendingPathComponent(session.id.uuidString).appendingPathComponent(try XCTUnwrap(checkpoint.files.first).path)
        let originalComplete = try Data(contentsOf: csv)
        var damaged = originalComplete; damaged.append(Data("2,0.123,".utf8)); try damaged.write(to: csv)
        let reopened = try LocalStore(root: root)
        let catalog = await reopened.catalog()
        XCTAssertEqual(catalog.sessions.first?.state, .interrupted)
        let recovered = try await reopened.recover(session.id)
        XCTAssertEqual(recovered.state, .recovered); XCTAssertNil(recovered.endedAt)
        XCTAssertEqual(try Data(contentsOf: csv), originalComplete)
        let evidence = try XCTUnwrap(recovered.evidence?.first { $0.path.hasSuffix(".csv") })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(session.id.uuidString).appendingPathComponent(evidence.path)), damaged)
        try await reopened.verify(session.id)
    }
    func testMalformedCompleteRowIsNotSilentlyRepaired() throws {
        let url = try temporary().appendingPathComponent("bad.csv")
        try Data((Sensor.accelerometer.header + "1,0.01,100,0.01,1,0,0,-1\n2,broken\n").utf8).write(to: url)
        var summary = StreamSummary(sensor: .accelerometer)
        XCTAssertThrowsError(try SessionFiles.scan(url, relative: "bad.csv", sensor: .accelerometer, allowPartialTail: true, summary: &summary))
    }
    func testFractionalDatesRoundTripWithinOneMillisecond() throws {
        let event = SessionEvent(time: Date(timeIntervalSince1970: 1767225600.123456), kind: "MARKER", detail: "Test", elapsedSeconds: 0.123456)
        let data = try ManifestCodec.encoder().encode(event)
        let restored = try ManifestCodec.decoder().decode(SessionEvent.self, from: data)
        XCTAssertEqual(restored.time.timeIntervalSince1970, event.time.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(restored.elapsedSeconds, event.elapsedSeconds)
    }
}
