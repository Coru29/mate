import Foundation

/// One GitHub release as the updater needs it.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    public let page: URL
    public let dmg: URL?
    public let notes: String
    public let prerelease: Bool
    public let draft: Bool
}

/// Reads GitHub's `/releases` list and picks the update to offer. The list (not `/releases/latest`) is used because
/// `latest` skips pre-releases, and every 0.x release is published as one.
public enum UpdateFeed {
    public static let dmgName = "Mate.dmg"

    /// A release list or a single release object; entries without a version tag or a page are skipped.
    public static func parse(_ data: Data) -> [ReleaseInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let objects = json as? [[String: Any]] ?? (json as? [String: Any]).map { [$0] } ?? []
        return objects.compactMap(release)
    }

    private static func release(_ json: [String: Any]) -> ReleaseInfo? {
        guard let tag = json["tag_name"] as? String, let version = AppVersion(tag),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { a -> (String, URL)? in
            guard let name = a["name"] as? String,
                  let url = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (name, url)
        }
        let dmg = assets.first { $0.0 == dmgName } ?? assets.first { $0.0.lowercased().hasSuffix(".dmg") }
        return ReleaseInfo(version: version, page: page, dmg: dmg?.1, notes: json["body"] as? String ?? "",
                           prerelease: json["prerelease"] as? Bool ?? false, draft: json["draft"] as? Bool ?? false)
    }

    /// The highest release newer than `current`. Drafts never count; pre-releases count only while the running
    /// version is 0.x, so a 1.x copy sticks to stable releases.
    public static func newest(_ releases: [ReleaseInfo], current: AppVersion) -> ReleaseInfo? {
        releases
            .filter { !$0.draft && (!$0.prerelease || current.isPreStable) && $0.version > current }
            .max { $0.version < $1.version }
    }
}

/// Release notes are bilingual: Spanish, then the `<!-- en -->` separator, then English (the website splits on it too).
public enum ReleaseNotes {
    public static let separator = "<!-- en -->"

    /// The half in the app's language; an empty half falls back to the other one, and notes without the separator
    /// are shown whole.
    public static func localized(_ body: String, english: Bool) -> String {
        let halves = body.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard halves.count >= 2 else { return halves.first ?? "" }
        let spanish = halves[0], other = halves[1...].joined(separator: "\n\n")
        let preferred = english ? other : spanish, fallback = english ? spanish : other
        return preferred.isEmpty ? fallback : preferred
    }
}
