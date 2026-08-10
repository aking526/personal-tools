import Foundation

/// Reads and writes the whole store as one JSON file. The dataset is a few hundred KB
/// after years of use, so whole-file rewrites are cheaper than any alternative.
nonisolated struct Storage {
    let url: URL

    /// Under the app sandbox this resolves inside
    /// ~/Library/Containers/com.alistair.TimeJournal/Data/...
    ///
    /// History written before the TimeLogger -> TimeJournal rename lives in the old
    /// com.alistair.TimeLogger container, which the sandbox puts out of reach. That
    /// data was copied across by hand at rename time; the app has no migration path
    /// of its own and does not look for it.
    static func appSupport() -> Storage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Storage(url: base.appendingPathComponent("TimeJournal/store.json"))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A missing file is a first launch, not an error. Malformed contents ARE an error —
    /// returning an empty store would let the next save destroy the real history.
    func load() throws -> Store {
        guard FileManager.default.fileExists(atPath: url.path) else { return Store() }
        return try Self.decoder.decode(Store.self, from: Data(contentsOf: url))
    }

    func save(_ store: Store) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.encoder.encode(store).write(to: url, options: .atomic)
    }
}
