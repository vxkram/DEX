import Foundation
import JobSystem
import Testing

@Suite("SafeOutput")
struct SafeOutputTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dex-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func touch(_ name: String, _ contents: String = "x") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func defaultNameChangesExtensionNextToSource() throws {
        defer { cleanUp() }
        let source = try touch("photo.heic")
        #expect(SafeOutput.defaultDestination(for: source, pathExtension: "jpg").lastPathComponent == "photo.jpg")
    }

    @Test func defaultNameAvoidsCollisionsIncludingTheSource() throws {
        defer { cleanUp() }
        let source = try touch("photo.jpg")
        _ = try touch("photo 2.jpg")
        #expect(SafeOutput.defaultDestination(for: source, pathExtension: "jpg").lastPathComponent == "photo 3.jpg")
    }

    @Test func writesAtomically() throws {
        defer { cleanUp() }
        let source = try touch("in.txt")
        let destination = folder.appendingPathComponent("out.txt")
        try SafeOutput.write(to: destination, source: source) { try Data("result".utf8).write(to: $0) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "result")
    }

    @Test func neverOverwritesTheSourceEvenWithOverwriteAllowed() throws {
        defer { cleanUp() }
        let source = try touch("photo.jpg", "original")
        #expect(throws: OutputError.wouldOverwriteSource("photo.jpg")) {
            try SafeOutput.write(to: source, source: source, overwrite: true) { try Data("bad".utf8).write(to: $0) }
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    }

    @Test func detectsTheSourceThroughASymlink() throws {
        defer { cleanUp() }
        let source = try touch("photo.jpg", "original")
        let link = folder.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(SafeOutput.isSameFile(link, source))
        #expect(throws: OutputError.self) {
            try SafeOutput.write(to: link, source: source, overwrite: true) { try Data("bad".utf8).write(to: $0) }
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    }

    @Test func refusesExistingDestinationUnlessAllowed() throws {
        defer { cleanUp() }
        let source = try touch("in.txt")
        let existing = try touch("out.txt", "old")
        #expect(throws: OutputError.destinationExists("out.txt")) {
            try SafeOutput.write(to: existing, source: source) { try Data("new".utf8).write(to: $0) }
        }
        try SafeOutput.write(to: existing, source: source, overwrite: true) { try Data("new".utf8).write(to: $0) }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "new")
    }

    @Test func failureLeavesNothingBehind() throws {
        defer { cleanUp() }
        struct Boom: Error {}
        let source = try touch("in.txt")
        let destination = folder.appendingPathComponent("out.txt")
        #expect(throws: Boom.self) {
            try SafeOutput.write(to: destination, source: source) { temporary in
                try Data("partial".utf8).write(to: temporary)
                throw Boom()
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["in.txt"])
    }

    @Test func refusesMissingFolder() throws {
        defer { cleanUp() }
        let source = try touch("in.txt")
        let destination = folder.appendingPathComponent("nope/out.txt")
        #expect(throws: OutputError.self) { try SafeOutput.write(to: destination, source: source) { _ in } }
    }
}
