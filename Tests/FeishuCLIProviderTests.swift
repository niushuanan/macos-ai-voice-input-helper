import XCTest
@testable import PulseType

final class FeishuCLIProviderTests: XCTestCase {
    func testDetectAvailabilityUsesExplicitExecutableOverride() throws {
        let fixture = try makeExecutableFixture(fileName: "lark-cli")
        defer { fixture.cleanUp() }

        let availability = FeishuCLIProvider.detectAvailability(
            environment: ["PATH": ""],
            executableOverride: fixture.executableURL.path
        )

        XCTAssertEqual(availability.commandName, "lark-cli")
        XCTAssertEqual(availability.backend?.kind, .larkCLI)
        XCTAssertEqual(availability.backend?.executablePath, fixture.executableURL.path)
    }

    func testDetectAvailabilityResolvesDirectoryOverride() throws {
        let fixture = try makeExecutableFixture(fileName: "feishu")
        defer { fixture.cleanUp() }

        let availability = FeishuCLIProvider.detectAvailability(
            environment: ["PATH": ""],
            executableOverride: fixture.directoryURL.path
        )

        XCTAssertEqual(availability.commandName, "feishu")
        XCTAssertEqual(availability.backend?.kind, .feishu)
        XCTAssertEqual(availability.backend?.executablePath, fixture.executableURL.path)
    }

    func testDetectAvailabilityPrefersLarkCLIWhenBothExistInPath() throws {
        let fixture = try makeDualExecutableFixture()
        defer { fixture.cleanUp() }

        let availability = FeishuCLIProvider.detectAvailability(
            environment: ["PATH": fixture.directoryURL.path]
        )

        XCTAssertEqual(availability.commandName, "lark-cli")
        XCTAssertEqual(availability.backend?.kind, .larkCLI)
        XCTAssertEqual(availability.backend?.executablePath, fixture.larkCLIURL.path)
    }

    func testDetectAvailabilitySearchesAdditionalDirectories() throws {
        let fixture = try makeExecutableFixture(fileName: "lark-cli")
        defer { fixture.cleanUp() }

        let availability = FeishuCLIProvider.detectAvailability(
            environment: ["PATH": ""],
            executableOverride: nil,
            additionalSearchDirectories: [fixture.directoryURL.path]
        )

        XCTAssertEqual(availability.commandName, "lark-cli")
        XCTAssertEqual(availability.backend?.executablePath, fixture.executableURL.path)
    }

    private func makeExecutableFixture(fileName: String) throws -> ExecutableFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feishu-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let executableURL = directoryURL.appendingPathComponent(fileName)
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path
        )

        return ExecutableFixture(
            directoryURL: directoryURL,
            executableURL: executableURL,
            cleanUp: {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        )
    }

    private func makeDualExecutableFixture() throws -> DualExecutableFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feishu-cli-tests-dual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let larkCLIURL = directoryURL.appendingPathComponent("lark-cli")
        let feishuURL = directoryURL.appendingPathComponent("feishu")
        try "#!/bin/sh\nexit 0\n".write(to: larkCLIURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: feishuURL, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: larkCLIURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: feishuURL.path
        )

        return DualExecutableFixture(
            directoryURL: directoryURL,
            larkCLIURL: larkCLIURL,
            feishuURL: feishuURL,
            cleanUp: {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        )
    }
}

private struct ExecutableFixture {
    let directoryURL: URL
    let executableURL: URL
    let cleanUp: () -> Void
}

private struct DualExecutableFixture {
    let directoryURL: URL
    let larkCLIURL: URL
    let feishuURL: URL
    let cleanUp: () -> Void
}
