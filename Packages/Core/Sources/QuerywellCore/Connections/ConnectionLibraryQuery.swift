import Foundation

/// Which subset of the library the launcher sidebar is showing.
public enum FolderFilter: Hashable, Sendable {
    /// Every connection.
    case all
    /// Connections not in any (existing) folder.
    case unfiled
    /// Connections in the folder with this id.
    case folder(UUID)
    /// Connections marked ``ConnectionProfile/favourite``.
    case favourites
    /// Connections whose colour tag is of this kind.
    case tag(ColorTagKind)
}

/// How the launcher orders connections.
public enum ConnectionSort: String, Sendable, Hashable, CaseIterable {
    /// Most recently used first; never-used last; ties by name.
    case lastUsed
    /// Alphabetical (localized, numeric-aware); ties by creation date.
    case name
    /// Newest first; ties by name.
    case created
}

/// Search, filter and sort state of the connections launcher.
public struct ConnectionLibraryQuery: Sendable, Hashable {
    /// Free text. Whitespace-separated terms must ALL match (AND), each as a
    /// case- and diacritic-insensitive substring of the name, host, user, default
    /// database, SSH host, engine name or tag name.
    public var searchText: String
    public var folder: FolderFilter
    public var sort: ConnectionSort

    public init(searchText: String = "", folder: FolderFilter = .all, sort: ConnectionSort = .lastUsed) {
        self.searchText = searchText
        self.folder = folder
        self.sort = sort
    }

    /// The profiles of `library` that satisfy the folder filter and search text, sorted.
    public func apply(to library: ConnectionLibrary) -> [ConnectionProfile] {
        let folderIDs = Set(library.folders.map(\.id))
        let terms = Self.fold(searchText).split(whereSeparator: \.isWhitespace).map(String.init)
        let matched = library.profiles.filter { profile in
            Self.matches(profile, filter: folder, folderIDs: folderIDs)
                && (terms.isEmpty || Self.matches(profile, terms: terms))
        }
        return matched.sorted(by: sort.areInIncreasingOrder)
    }

    /// Number of connections behind each sidebar entry, ignoring the search text.
    ///
    /// Contains `.all`, `.unfiled`, `.favourites`, one `.folder` per library folder and
    /// one `.tag` per ``ColorTagKind`` (zero when empty).
    public func folderCounts(in library: ConnectionLibrary) -> [FolderFilter: Int] {
        let folderIDs = Set(library.folders.map(\.id))
        var counts: [FolderFilter: Int] = [.all: library.profiles.count, .unfiled: 0, .favourites: 0]
        for folder in library.folders { counts[.folder(folder.id)] = 0 }
        for kind in ColorTagKind.allCases { counts[.tag(kind)] = 0 }
        for profile in library.profiles {
            if let id = profile.folderID, folderIDs.contains(id) {
                counts[.folder(id), default: 0] += 1
            } else {
                counts[.unfiled, default: 0] += 1
            }
            if profile.favourite { counts[.favourites, default: 0] += 1 }
            if let tag = profile.colorTag { counts[.tag(tag.kind), default: 0] += 1 }
        }
        return counts
    }

    // MARK: Matching

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func matches(_ p: ConnectionProfile, filter: FolderFilter, folderIDs: Set<UUID>) -> Bool {
        switch filter {
        case .all: true
        case .unfiled: p.folderID.map { !folderIDs.contains($0) } ?? true
        case .folder(let id): p.folderID == id
        case .favourites: p.favourite
        case .tag(let kind): p.colorTag?.kind == kind
        }
    }

    private static func matches(_ p: ConnectionProfile, terms: [String]) -> Bool {
        var fields = [p.name, p.host, p.user, p.engine.displayName]
        if let db = p.defaultDatabase { fields.append(db) }
        if let ssh = p.ssh { fields.append(ssh.host) }
        if let tag = p.colorTag { fields.append(tag.displayName) }
        let haystack = fold(fields.joined(separator: "\n"))
        return terms.allSatisfy { haystack.contains($0) }
    }
}

extension ConnectionSort {
    fileprivate func areInIncreasingOrder(_ a: ConnectionProfile, _ b: ConnectionProfile) -> Bool {
        func byName() -> ComparisonResult { a.name.localizedStandardCompare(b.name) }
        func tieBreak() -> Bool {
            // Fully deterministic tie-break.
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
        switch self {
        case .name:
            let r = byName()
            return r == .orderedSame ? tieBreak() : r == .orderedAscending
        case .created:
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            let r = byName()
            return r == .orderedSame ? tieBreak() : r == .orderedAscending
        case .lastUsed:
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let r = byName()
                return r == .orderedSame ? tieBreak() : r == .orderedAscending
            }
        }
    }
}
