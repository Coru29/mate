import Testing
import Foundation
@testable import MateCore

private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, assets: String? = nil,
                     body: String = "notes") -> String {
    let list = assets ?? #"[{"name": "Mate.dmg", "browser_download_url": "https://github.com/Coru29/mate/releases/download/\#(tag)/Mate.dmg"}]"#
    return """
    {"tag_name": "\(tag)", "html_url": "https://github.com/Coru29/mate/releases/tag/\(tag)",
     "prerelease": \(prerelease), "draft": \(draft), "body": \(String(reflecting: body)), "assets": \(list)}
    """
}

private func feed(_ items: String...) -> Data { Data("[\(items.joined(separator: ","))]".utf8) }

struct UpdateFeedTests {
    @Test func parsesAReleaseList() {
        let releases = UpdateFeed.parse(feed(release("v0.2.0", prerelease: true), release("v0.1.0")))
        #expect(releases.map(\.version.description) == ["0.2.0", "0.1.0"])
        #expect(releases[0].prerelease)
        #expect(releases[0].page.absoluteString == "https://github.com/Coru29/mate/releases/tag/v0.2.0")
        #expect(releases[0].dmg?.absoluteString == "https://github.com/Coru29/mate/releases/download/v0.2.0/Mate.dmg")
        #expect(releases[0].notes == "notes")
    }

    @Test func acceptsASingleReleaseObject() {
        let releases = UpdateFeed.parse(Data(release("v0.3.0").utf8))
        #expect(releases.map(\.version.description) == ["0.3.0"])
    }

    @Test func skipsMalformedEntriesAndGarbage() {
        let bad = #"{"tag_name": "nightly", "html_url": "https://github.com/x"}"#
        let noPage = #"{"tag_name": "v0.4.0"}"#
        #expect(UpdateFeed.parse(feed(bad, noPage, release("v0.2.0"))).map(\.version.description) == ["0.2.0"])
        #expect(UpdateFeed.parse(Data("not json".utf8)).isEmpty)
        #expect(UpdateFeed.parse(Data(#"{"message": "Not Found"}"#.utf8)).isEmpty)
    }

    @Test func suffixedTagsAreNotReleases() {
        let releases = UpdateFeed.parse(feed(release("v0.3.0-beta.1", prerelease: true), release("0.2.1-rc1"),
                                             release("v0.2.0"), release("0.1.5")))
        #expect(releases.map(\.version.description) == ["0.2.0", "0.1.5"])
    }

    @Test func prefersTheMateDmgAsset() {
        let assets = #"""
        [{"name": "Other.dmg", "browser_download_url": "https://github.com/a/Other.dmg"},
         {"name": "Mate.dmg", "browser_download_url": "https://github.com/a/Mate.dmg"}]
        """#
        #expect(UpdateFeed.parse(feed(release("v0.2.0", assets: assets)))[0].dmg?.lastPathComponent == "Mate.dmg")
        let onlyOther = #"[{"name": "mate-0.2.0.DMG", "browser_download_url": "https://github.com/a/mate-0.2.0.DMG"}]"#
        #expect(UpdateFeed.parse(feed(release("v0.2.0", assets: onlyOther)))[0].dmg?.lastPathComponent == "mate-0.2.0.DMG")
        #expect(UpdateFeed.parse(feed(release("v0.2.0", assets: "[]")))[0].dmg == nil)
    }

    @Test func zeroVersionsTakePreReleases() {
        let releases = UpdateFeed.parse(feed(release("v0.3.0", prerelease: true), release("v0.2.0")))
        #expect(UpdateFeed.newest(releases, current: AppVersion("0.1.0")!)?.version.description == "0.3.0")
    }

    @Test func stableVersionsSkipPreReleases() {
        let releases = UpdateFeed.parse(feed(release("v1.1.0", prerelease: true), release("v1.0.1")))
        #expect(UpdateFeed.newest(releases, current: AppVersion("1.0.0")!)?.version.description == "1.0.1")
        #expect(UpdateFeed.newest(Array(releases.prefix(1)), current: AppVersion("1.0.0")!) == nil)
    }

    @Test func draftsAreNeverOffered() {
        let releases = UpdateFeed.parse(feed(release("v0.5.0", draft: true), release("v0.2.0", prerelease: true)))
        #expect(UpdateFeed.newest(releases, current: AppVersion("0.1.0")!)?.version.description == "0.2.0")
    }

    @Test func picksTheHighestVersionWhateverTheOrder() {
        let releases = UpdateFeed.parse(feed(release("v0.2.0"), release("v0.10.0"), release("v0.9.0")))
        #expect(UpdateFeed.newest(releases, current: AppVersion("0.1.0")!)?.version.description == "0.10.0")
    }

    @Test func nothingWhenUpToDate() {
        let releases = UpdateFeed.parse(feed(release("v0.2.0"), release("v0.1.0")))
        #expect(UpdateFeed.newest(releases, current: AppVersion("0.2.0")!) == nil)
        #expect(UpdateFeed.newest([], current: AppVersion("0.2.0")!) == nil)
    }
}

struct ReleaseNotesTests {
    private let body = "### Novedades\n\n- Algo\n\n<!-- en -->\n\n### Features\n\n- Something\n"

    @Test func spanishIsTheFirstPart() {
        #expect(ReleaseNotes.localized(body, english: false) == "### Novedades\n\n- Algo")
    }

    @Test func englishIsTheSecondPart() {
        #expect(ReleaseNotes.localized(body, english: true) == "### Features\n\n- Something")
    }

    @Test func withoutSeparatorTheWholeBody() {
        #expect(ReleaseNotes.localized("  - Fix  \n", english: true) == "- Fix")
        #expect(ReleaseNotes.localized("- Fix", english: false) == "- Fix")
    }

    @Test func anEmptyHalfFallsBackToTheOther() {
        #expect(ReleaseNotes.localized("- Algo\n<!-- en -->\n", english: true) == "- Algo")
        #expect(ReleaseNotes.localized("<!-- en -->\n- Something", english: false) == "- Something")
    }
}
