import SwiftUI

extension Notification.Name {
    static let pcAddFonts = Notification.Name("PhotoCraftAddFonts")
    static let pcUIScale = Notification.Name("PhotoCraftUIScale")
    static let pcOpenURL = Notification.Name("PhotoCraftOpenURL")
}

@main
struct PhotoCraftApp: App {
    init() {
        // Before any window exists, so PhotoCraft finds the iPad's fonts when it starts.
        SystemFonts.prepare()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(red: 0.09, green: 0.09, blue: 0.10).ignoresSafeArea()
                PhotoCraftHost()
            }
            .statusBarHidden(true)
            .onOpenURL { url in
                NotificationCenter.default.post(name: .pcOpenURL, object: url)
            }
        }
        .commands {
            CommandMenu("Interface") {
                Button("Larger Interface") {
                    NotificationCenter.default.post(name: .pcUIScale, object: nil, userInfo: ["delta": Float(0.1)])
                }
                .keyboardShortcut("=", modifiers: [.command, .control])
                Button("Smaller Interface") {
                    NotificationCenter.default.post(name: .pcUIScale, object: nil, userInfo: ["delta": Float(-0.1)])
                }
                .keyboardShortcut("-", modifiers: [.command, .control])
                Button("Reset Interface Size") {
                    NotificationCenter.default.post(name: .pcUIScale, object: nil, userInfo: ["reset": true])
                }
                .keyboardShortcut("0", modifiers: [.command, .control])
            }
            CommandMenu("Fonts") {
                Button("Add Installed Fonts…") {
                    NotificationCenter.default.post(name: .pcAddFonts, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
            }
        }
    }
}

struct PhotoCraftHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PhotoCraftViewController { PhotoCraftViewController() }
    func updateUIViewController(_ vc: PhotoCraftViewController, context: Context) {}
}
