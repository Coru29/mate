import AppKit
import SwiftUI

/// "Acerca de": icon, version, repository and license.
struct AboutView: View {
    private static let repository = URL(string: "https://github.com/Coru29/mate")!

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(verbatim: "Mate")
                .font(.system(size: 28, weight: .semibold))
            Text(Self.versionText)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Los límites de uso de tus agentes de IA, en el notch. Gratis y open source.")
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            Link(destination: Self.repository) { Text(verbatim: "github.com/Coru29/mate") }
            Text("Licencia MIT")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Versión 1.0.0 (3)"; a build run outside the app bundle has no Info.plist.
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            return String(localized: "Versión de desarrollo")
        }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != version {
            return String(localized: "Versión \(version) (\(build))")
        }
        return String(localized: "Versión \(version)")
    }
}
