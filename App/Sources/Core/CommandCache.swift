import Foundation

struct CachedCommands: Codable, Equatable, Sendable {
    /// Base URL the list came from; a list from another server is never shown.
    let server: String
    let rev: String
    let commands: [PaletteCommand]
}

protocol CommandCaching: Sendable {
    func load(server: String) -> CachedCommands?
    func save(_ cached: CachedCommands)
}

/// Last good command list as one JSON file, so the palette still has something (greyed) when the Mac is off.
struct DiskCommandCache: CommandCaching {
    let fileURL: URL

    static var standard: DiskCommandCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return DiskCommandCache(fileURL: base.appendingPathComponent("commands-cache.json"))
    }

    func load(server: String) -> CachedCommands? {
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder.palette.decode(CachedCommands.self, from: data),
              cached.server == server else { return nil }
        return cached
    }

    func save(_ cached: CachedCommands) {
        guard let data = try? JSONEncoder.palette.encode(cached) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
