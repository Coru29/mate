import Foundation

public enum LogDirs {
    /// The config dir whose log root contains `path`, matching the root as given and with symlinks resolved.
    public static func configDir(forLogFile path: String, roots: [(dir: String, root: String)]) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return roots.first { r in
            [r.root, URL(fileURLWithPath: r.root).resolvingSymlinksInPath().path]
                .contains { path.hasPrefix($0 + "/") || resolved.hasPrefix($0 + "/") }
        }?.dir
    }

    /// A config dir the user added, in the form a shell gives `CLAUDE_CONFIG_DIR` / `CODEX_HOME` (whose exact value
    /// names Claude Code's keychain item): `~` expanded, relative paths made absolute, trailing slashes dropped, and
    /// nothing else changed (no symlink or `/private` rewriting).
    public static func canonicalConfigDir(_ path: String, home: String, cwd: String) -> String {
        var s = path
        if s == "~" || s.hasPrefix("~/") { s = home + s.dropFirst() }
        if !s.hasPrefix("/") { s = cwd + "/" + s }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
