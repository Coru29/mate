// Computes the next version from Conventional Commits since the last release tag and writes the release notes.
//   1.0 and later: feat: → minor   fix: / perf: → patch   "!" after the type or a "BREAKING CHANGE:" footer → major
//   0.x (pre-1.0):  feat: or a breaking change → minor (0.1 → 0.2)   fix: / perf: → patch
//   1.0.0 never happens by itself: pass --major, or edit VERSION by hand (a VERSION ahead of the last tag wins).
//   Other types (docs, chore, refactor, test, build, ci, style) do not trigger a release.
// Usage: swift scripts/next-version.swift [--major] [notes-output-file]
// Prints the next version ("0.2.0") or "none". With no previous v* tag it releases the VERSION file as is, and
// its notes only say it is the first release.
// The notes are bilingual: Spanish, then the "<!-- en -->" separator, then English (the app and the website split on it).
import Foundation

func git(_ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

struct Commit { let type: String; let scope: String?; let breaking: Bool; let summary: String; let hash: String }

/// "feat(updates)!: text" → Commit. Non-conventional subjects return nil.
func parse(subject: String, body: String, hash: String) -> Commit? {
    let pattern = #"^([a-z]+)(\(([^)]+)\))?(!)?: (.+)$"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(subject.startIndex..., in: subject)
    guard let m = regex.firstMatch(in: subject, range: range) else { return nil }
    func group(_ i: Int) -> String? { Range(m.range(at: i), in: subject).map { String(subject[$0]) } }
    let breaking = group(4) != nil || body.contains("BREAKING CHANGE:") || body.contains("BREAKING-CHANGE:")
    return Commit(type: group(1)!, scope: group(3), breaking: breaking, summary: group(5)!, hash: String(hash.prefix(7)))
}

func numbers(_ version: String) -> [Int] {
    var parts = version.split(separator: ".").compactMap { Int($0) }
    while parts.count < 3 { parts.append(0) }
    return Array(parts.prefix(3))
}

var args = Array(CommandLine.arguments.dropFirst())
let major = args.contains("--major")
args.removeAll { $0 == "--major" }
let notesPath = args.first
let root = git(["rev-parse", "--show-toplevel"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
let fileVersion = (try? String(contentsOfFile: root + "/VERSION", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.1.0"
let lastTag = git(["describe", "--tags", "--abbrev=0", "--match", "v[0-9]*"])
let hasTag = lastTag.status == 0
let tag = lastTag.out.trimmingCharacters(in: .whitespacesAndNewlines)
let range = hasTag ? "\(tag)..HEAD" : "HEAD"
let log = git(["log", range, "--no-merges", "--format=%H%x1f%s%x1f%b%x1e"]).out
let commits = log.split(separator: "\u{1e}").compactMap { record -> Commit? in
    let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
    guard fields.count >= 2 else { return nil }
    return parse(subject: fields[1], body: fields.count > 2 ? fields[2] : "", hash: fields[0])
}

let base = numbers(hasTag ? String(tag.dropFirst()) : fileVersion)
let manual = numbers(fileVersion)
let preStable = base[0] == 0
let next: String
if major {
    next = "\(base[0] + 1).0.0"
} else if !hasTag || base.lexicographicallyPrecedes(manual) {
    // First release, or VERSION edited by hand past the last tag (how 1.0.0 is chosen without --major).
    next = fileVersion
} else if commits.contains(where: \.breaking) && !preStable {
    next = "\(base[0] + 1).0.0"
} else if commits.contains(where: { $0.type == "feat" || $0.breaking }) {
    next = "\(base[0]).\(base[1] + 1).0"
} else if commits.contains(where: { $0.type == "fix" || $0.type == "perf" }) {
    next = "\(base[0]).\(base[1]).\(base[2] + 1)"
} else {
    print("none")
    exit(0)
}

func section(_ title: String, _ items: [Commit]) -> String {
    guard !items.isEmpty else { return "" }
    let lines = items.map { c -> String in
        let scope = c.scope.map { "**\($0):** " } ?? ""
        let first = c.summary.prefix(1).uppercased() + c.summary.dropFirst()
        return "- \(scope)\(first) (\(c.hash))"
    }
    return "### \(title)\n\n" + lines.joined(separator: "\n") + "\n\n"
}

/// One language's half of the notes. Commit summaries are written in English; the headings follow the language.
func notes(_ titles: (breaking: String, feat: String, fix: String, perf: String), first: String, download: String) -> String {
    // The first release lists no commits: the whole history up to it is the app itself.
    guard hasTag else {
        return first + "\n\n**\(download):** [Mate.dmg](https://github.com/Coru29/mate/releases/download/v\(next)/Mate.dmg)\n"
    }
    var out = ""
    out += section(titles.breaking, commits.filter(\.breaking))
    out += section(titles.feat, commits.filter { $0.type == "feat" && !$0.breaking })
    out += section(titles.fix, commits.filter { $0.type == "fix" && !$0.breaking })
    out += section(titles.perf, commits.filter { $0.type == "perf" && !$0.breaking })
    return out + "**\(download):** [Mate.dmg](https://github.com/Coru29/mate/releases/download/v\(next)/Mate.dmg)\n"
}

let spanish = notes(("Cambios incompatibles", "Novedades", "Arreglos", "Rendimiento"),
                    first: "Primera versión pública.", download: "Descargar")
let english = notes(("Breaking changes", "Features", "Fixes", "Performance"),
                    first: "First public release.", download: "Download")
let text = spanish + "\n<!-- en -->\n\n" + english
if let notesPath { try? text.write(toFile: notesPath, atomically: false, encoding: .utf8) }
print(next)
