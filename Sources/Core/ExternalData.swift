//
//  ExternalData.swift
//  SCOPECaptureCore
//
//  Created by MD. Raiyan Haque on 10/22/26.
//

import Foundation
import CryptoKit

struct ExternalDeviceProfile: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var manufacturer: String
    var model: String
    var notes: String
}

struct ExternalFileRecord: Codable, Identifiable, Sendable {
    var path: String
    var originalName: String
    var bytes: Int64
    var sha256: String
    var importedAt: Date
    var device: ExternalDeviceProfile
    var source: String
    var id: String { path }
}

extension LocalStore {
    func rename(_ id: UUID, title: String) throws {
        guard current == nil else { throw RecorderError(message: "Finish recording before renaming a session.") }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RecorderError(message: "Enter a session name between 1 and 120 characters without line breaks.")
        }
        var session = try load(id)
        guard session.experiment != title else { return }
        session.events.append(SessionEvent(time: Date(), kind: "SESSION_RENAMED", detail: "Renamed from \(session.experiment) to \(title)."))
        session.experiment = title
        try persist(session)
    }

    func createExternalSession(title: String, device: String, os: String, app: String) throws -> ResearchSession {
        guard current == nil else { throw RecorderError(message: "Finish the phone recording first.") }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw RecorderError(message: "Enter a session name, up to 120 characters.") }
        let now = Date()
        let session = ResearchSession(schemaVersion: 3, id: UUID(), experiment: title,
            participant: "", notes: "External files retain their original byte content. Import time is not acquisition time.",
            startedAt: now, endedAt: now, lastCheckpoint: now, device: device, osVersion: os,
            appVersion: app, selected: [], available: [], state: .incomplete,
            durationSeconds: 0, summaries: [], evidence: [], externalFiles: [])
        try FileManager.default.createDirectory(at: folder(session.id), withIntermediateDirectories: false)
        do { try persist(session) }
        catch { try? FileManager.default.removeItem(at: folder(session.id)); throw error }
        return session
    }

    /// Import opaque files without decoding, conversion or newline normalization.
    /// The document-provider coordinator and disk I/O run on this storage actor.
    func attachExternalFiles(_ urls: [URL], to id: UUID, device: ExternalDeviceProfile,
                             source: String = "document_picker") throws {
        guard current == nil else { throw RecorderError(message: "Finish the phone recording before importing files.") }
        guard !urls.isEmpty, urls.count <= 100 else { throw RecorderError(message: "Choose between 1 and 100 files per import.") }
        guard !device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              device.name.count <= 120, device.manufacturer.count <= 120, device.model.count <= 120, device.notes.count <= 2000 else {
            throw RecorderError(message: "Check the device name and shorten its details.")
        }
        var session = try load(id)
        guard session.schemaVersion >= 2 else { throw RecorderError(message: "Attach files to a new session; legacy format 1 recordings remain read-only.") }
        guard session.state.exportable || (session.state == .incomplete && session.selected.isEmpty) else {
            throw RecorderError(message: "Recover the session before attaching external files.")
        }
        let relative = "external/\(device.id.uuidString)/\(UUID().uuidString)"
        let destination = try SessionFiles.safeURL(root: folder(id), relative: relative)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: destination) } }
        var records: [ExternalFileRecord] = []
        let storageRoot = root
        for (index, url) in urls.enumerated() {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let fileName = url.lastPathComponent
            guard !fileName.isEmpty, fileName != ".", fileName != "..", !fileName.contains("/"), !fileName.contains("\\"),
                  fileName.utf8.count <= 240, !fileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw RecorderError(message: "Rename the source file to a shorter, ordinary filename before importing.")
            }
            let child = destination.appendingPathComponent(String(index + 1), isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            let output = child.appendingPathComponent(fileName)
            var result: Result<(Int64, String), Error>?
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                result = Result { try Self.copyExternalFile(readable, to: output, storageRoot: storageRoot) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw RecorderError(message: "The file provider did not supply this file.") }
            let (bytes, sha256) = try result.get()
            records.append(ExternalFileRecord(path: relative + "/\(index + 1)/" + fileName,
                originalName: fileName, bytes: bytes, sha256: sha256, importedAt: Date(), device: device, source: source))
        }
        session.externalFiles = (session.externalFiles ?? []) + records
        session.schemaVersion = 3
        session.events.append(SessionEvent(time: Date(), kind: "EXTERNAL_FILES_IMPORTED",
            detail: "Imported \(records.count) file(s) from \(device.name). Byte counts and SHA-256 checked. Import time is not acquisition time."))
        if session.selected.isEmpty { session.state = .localComplete }
        try persist(session)
        committed = true
    }

    private nonisolated static func copyExternalFile(_ source: URL, to destination: URL, storageRoot: URL) throws -> (Int64, String) {
        func availableBytes() throws -> Int64 {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: storageRoot.path)
            guard let value = attributes[.systemFreeSize] as? NSNumber else {
                throw RecorderError(message: "Cannot determine free space for the import.")
            }
            return value.int64Value
        }
        let before = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard before.isRegularFile == true, before.isSymbolicLink != true else {
            throw RecorderError(message: "Select regular files. Folders and symbolic links are not imported.")
        }
        if let size = before.fileSize {
            guard try availableBytes() - Int64(size) >= Self.minimumFreeBytes else {
                throw RecorderError(message: "Not enough space to copy this external file safely.")
            }
        }
        try Data().write(to: destination, options: .withoutOverwriting)
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        var digest = SHA256(), bytes: Int64 = 0, checked: Int64 = 0
        while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty {
            if bytes >= checked {
                guard try availableBytes() >= Self.minimumFreeBytes else { throw RecorderError(message: "Import stopped: storage reserve reached.") }
                checked = bytes + 4 * 1024 * 1024
            }
            try writer.write(contentsOf: chunk)
            digest.update(data: chunk); bytes += Int64(chunk.count)
        }
        try writer.synchronize(); try writer.close()
        let sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let destinationHash = try SessionFiles.fingerprint(destination)
        let sourceHash = try SessionFiles.fingerprint(source)
        let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard destinationHash.0 == bytes, destinationHash.1 == sha256,
              sourceHash.0 == bytes, sourceHash.1 == sha256,
              before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw RecorderError(message: "The source changed or its copy failed integrity verification. Stop the logger, then retry.")
        }
        return (bytes, sha256)
    }
}
