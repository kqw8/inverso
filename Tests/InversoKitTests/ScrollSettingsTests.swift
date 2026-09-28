import Foundation
import InversoKit
import XCTest

final class ScrollSettingsTests: XCTestCase {
    func testAcceptsFiniteMultipliersWithinInclusiveRange() throws {
        for multiplier in [0.25, 1, 1.5, 4] {
            XCTAssertEqual(try ScrollSettings(speedMultiplier: multiplier).speedMultiplier, multiplier)
        }
    }

    func testRejectsOutOfRangeAndNonfiniteMultipliers() {
        for multiplier in [0, -1, 0.249, 4.001, Double.infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try ScrollSettings(speedMultiplier: multiplier))
        }
    }

    func testDecodingValidatesSavedMultiplier() throws {
        let valid = Data(#"{"speedMultiplier":1.5}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ScrollSettings.self, from: valid).speedMultiplier, 1.5)
        for json in [#"{"speedMultiplier":0}"#, #"{"speedMultiplier":4.1}"#,
                     #"{"speedMultiplier":"nan"}"#, #"{}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ScrollSettings.self, from: Data(json.utf8)))
        }
    }

    func testMissingSettingsReturnNormalSpeedWithoutCreatingFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Inverso/settings.json")
        XCTAssertEqual(try ScrollSettingsStore.load(from: url).speedMultiplier, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSaveCreatesParentAndReplacesSettingsWithValidJSON() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Inverso/settings.json")
        try ScrollSettingsStore.save(ScrollSettings(speedMultiplier: 1.5), to: url)
        XCTAssertEqual(try ScrollSettingsStore.load(from: url).speedMultiplier, 1.5)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Double])
        XCTAssertEqual(json["speedMultiplier"], 1.5)
        try ScrollSettingsStore.save(ScrollSettings(speedMultiplier: 2), to: url)
        XCTAssertEqual(try ScrollSettingsStore.load(from: url).speedMultiplier, 2)
    }

    func testMalformedSavedSettingsThrowInsteadOfSilentlyResetting() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        for json in ["not json", #"{"speedMultiplier":0}"#, #"{}"#] {
            try Data(json.utf8).write(to: url)
            XCTAssertThrowsError(try ScrollSettingsStore.load(from: url))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), json)
        }
    }

    func testReadErrorsOtherThanMissingFileAreReported() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ScrollSettingsStore.load(from: directory))
    }

    func testRejectedSpeedCommandCannotClobberSavedSettings() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try ScrollSettingsStore.save(ScrollSettings(speedMultiplier: 1.5), to: url)
        let saved = try Data(contentsOf: url)
        for arguments in [["speed", "nan"], ["speed", "5"], ["speed", "2", "extra"]] {
            XCTAssertThrowsError(try {
                if case .speed(let multiplier) = try CLIOptions(arguments: arguments), let multiplier {
                    try ScrollSettingsStore.save(ScrollSettings(speedMultiplier: multiplier), to: url)
                }
            }())
            XCTAssertEqual(try Data(contentsOf: url), saved)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inverso-settings-\(UUID().uuidString)")
    }
}
