import SwiftUI

extension Notification.Name {
    static let pcAddFonts = Notification.Name("PhotoCraftAddFonts")
    static let pcPhotosSaved = Notification.Name("PhotoCraftPhotosSaved")
    static let pcOpenURL = Notification.Name("PhotoCraftOpenURL")
}

@main
struct PhotoCraftApp: App {
    init() {
        // Before any window exists, so PhotoCraft finds the iPad's fonts when it starts.
        SystemFonts.prepare()
        // Reopen access to the files you used recently, so Recent files still open.
        FileAccess.shared.restore()
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
