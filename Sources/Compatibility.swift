import Foundation

// Stable identifiers and migration sources for installations from before the rename.
// Keep these values literal: replacing them would orphan existing credentials/data.
enum Compatibility {
    static let keychainService = "com.mycast.personal.chatgpt"
    static let legacyDataFolder = "MyCast"
    static let welcomeTitles = ["MyCast에 오신 걸 환영해요", "갈피에 오신 걸 환영해요"]

    static func dataDirectory(applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) throws -> URL {
        let fm = FileManager.default
        let target = applicationSupport.appendingPathComponent("Galpi", isDirectory: true)
        let legacy = applicationSupport.appendingPathComponent(legacyDataFolder, isDirectory: true)
        if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: legacy.path) {
            do {
                _ = try JSONDecoder().decode(Library.self, from: Data(contentsOf: legacy.appendingPathComponent("library.json")))
                // Same-volume rename is atomic; an existing destination is never replaced.
                try fm.moveItem(at: legacy, to: target)
            } catch {
                throw AppError("이전 데이터를 옮기지 못했어요. 원본을 보존했어요. 데이터 폴더: \(legacy.path)\n\(error.localizedDescription)")
            }
        }
        return target
    }

    static func migrateWindowFrame(defaults: UserDefaults = .standard) {
        let previous = "NSWindow Frame MyCastMainWindow"
        let current = "NSWindow Frame GalpiMainWindow"
        if defaults.object(forKey: current) == nil, let frame = defaults.string(forKey: previous) {
            defaults.set(frame, forKey: current)
        }
    }
}
