import Foundation

public struct ScrollSettings: Codable, Equatable {
    public let speedMultiplier: Double

    public static let defaultValue = ScrollSettings(validatedSpeedMultiplier: 1)

    public struct ValidationError: Error, CustomStringConvertible {
        public var description: String { "Scroll speed must be a finite number from 0.25 to 4." }
    }

    public init(speedMultiplier: Double) throws {
        guard speedMultiplier.isFinite, (0.25...4).contains(speedMultiplier) else {
            throw ValidationError()
        }
        self.speedMultiplier = speedMultiplier
    }

    private init(validatedSpeedMultiplier: Double) {
        speedMultiplier = validatedSpeedMultiplier
    }

    private enum CodingKeys: String, CodingKey {
        case speedMultiplier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(speedMultiplier: container.decode(Double.self, forKey: .speedMultiplier))
    }
}

public enum ScrollSettingsStore {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Inverso/settings.json")

    public static func load(from url: URL = defaultURL) throws -> ScrollSettings {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return .defaultValue
        }
        return try JSONDecoder().decode(ScrollSettings.self, from: data)
    }

    public static func save(_ settings: ScrollSettings, to url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
