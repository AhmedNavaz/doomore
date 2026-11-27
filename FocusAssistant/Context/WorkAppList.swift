import Foundation

/// Pure helpers for the editable list of work apps (bundle identifiers only).
enum WorkAppList {
    /// Trims, drops empties and duplicates, and returns a stable sorted list.
    static func normalized(_ ids: some Sequence<String>) -> [String] {
        Array(Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    static func adding(_ id: String, to ids: [String]) -> [String] { normalized(ids + [id]) }

    static func removing(_ id: String, from ids: [String]) -> [String] { normalized(ids.filter { $0 != id }) }
}
