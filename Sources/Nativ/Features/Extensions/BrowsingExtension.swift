import NativExtensionSDK
import SwiftUI

@MainActor
final class BrowsingExtension: NativHostExtension {
    let manifest = NativExtensionManifest(
        id: NativExtensionManager.browsingID,
        version: "1.0.0",
        minimumNativVersion: "0.1.0",
        displayName: "Browsing",
        summary: "Web search and page reading for chat and research.",
        developer: "Nativ",
        systemImage: "globe",
        included: true,
        enabledByDefault: true,
        runtime: .builtIn,
        contributions: .init(
            settings: [
                .init(
                    id: "com.nativ.browsing.providers",
                    title: "Search and page-reading providers"
                )
            ]
        )
    )

    func activate(context _: NativExtensionHostContext) {}
    func deactivate() {}

    func makePage(
        id _: String,
        context _: NativExtensionPageContext
    ) -> AnyView? {
        nil
    }
}
