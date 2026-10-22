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
}
