import UIKit
import UniformTypeIdentifiers

/// Writes a line to PhotoCraft-log.txt (visible in Files: On My iPad > PhotoCraft).
func pcLog(_ message: String) {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let url = docs.appendingPathComponent("PhotoCraft-log.txt")
    let line = "[swift] \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Owns the drawing view and everything that needs Apple's own screens: Files, alerts, the
/// font picker.
///
/// Saving: the app writes its file into Documents/Working. The first time (Save As, a first
/// save, an export) this class offers that file to Apple's Save to Files sheet. After that, the
/// app's Save writes the working copy silently, and this class copies it to the file the person
/// chose, about a second later.
final class PhotoCraftViewController: UIViewController, UIDocumentPickerDelegate, UIFontPickerViewControllerDelegate {

    private let metal = MetalView()
    private enum Mode { case open, export }
    private var mode: Mode = .open

    /// Working file name -> the file the person chose in the Save to Files sheet.
    private var targets: [String: URL] = [:]
    /// Working file name -> when its working copy was last copied to the chosen file.
    private var lastCopied: [String: Date] = [:]
    private var mirrorTimer: Timer?
    /// The working file the Save to Files sheet on screen is offering.
    private var exportingName: String?
    /// Working files waiting for the Save to Files sheet.
    private var exportQueue: [String] = []

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    private var workingFolder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Working", isDirectory: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)

        metal.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metal)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            metal.topAnchor.constraint(equalTo: guide.topAnchor),
            metal.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            metal.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            metal.trailingAnchor.constraint(equalTo: guide.trailingAnchor)
        ])

        metal.onOpenDialog = { [weak self] multiple in self?.showOpenSheet(multiple: multiple) }
        metal.onExport = { [weak self] path in self?.offerToFiles(path: path) }
        metal.onOpenURL = { url in
            guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return }
            UIApplication.shared.open(u)
        }
        metal.onCopyText = { UIPasteboard.general.string = $0 }

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.mirrorWorkingCopies()
            self?.metal.saveState()
            self?.metal.setFocused(false)
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.metal.setFocused(true)
        }
        nc.addObserver(forName: .pcAddFonts, object: nil, queue: .main) { [weak self] _ in
            self?.showFontPicker()
        }
        nc.addObserver(forName: .pcUIScale, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            if (info?["reset"] as? Bool) == true {
                self?.metal.adjustUIScale(delta: nil, reset: true)
            } else if let d = info?["delta"] as? Float {
                self?.metal.adjustUIScale(delta: d, reset: false)
            }
        }
        nc.addObserver(forName: .pcOpenURL, object: nil, queue: .main) { [weak self] note in
            guard let url = note.object as? URL else { return }
            self?.openFromOutside(url)
        }

        mirrorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.mirrorWorkingCopies()
        }
    }

    // MARK: Fonts

    /// Apple's own font picker: the only way an app can use fonts installed on the iPad.
    private func showFontPicker() {
        guard presentedViewController == nil, view.window?.isKeyWindow ?? true else { return }
        var configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = false
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = self
        metal.suspendFocus = true
        present(picker, animated: true)
    }

    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        metal.suspendFocus = false
        guard let descriptor = viewController.selectedFontDescriptor else { return }
        let stored = SystemFonts.addPicked(descriptor)
        if presentedViewController != nil { dismiss(animated: true) }
        let family = (descriptor.object(forKey: .family) as? String) ?? "the font"
        if stored.isEmpty {
            message("Couldn’t add the font", "iPadOS did not let PhotoCraft copy “\(family)”. Some protected fonts can’t be used.")
        } else {
            message("Font added", "Added \(stored.count) style(s) of “\(family)”. Restart PhotoCraft once to use \(stored.count == 1 ? "it" : "them").")
        }
    }

    func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
        metal.suspendFocus = false
    }

    // MARK: Opening files

    /// Apple's Open sheet. Files are returned as copies, so tapping a file opens it at once.
    private func showOpenSheet(multiple: Bool) {
        pcLog("open sheet requested; several: \(multiple); already presenting: \(presentedViewController != nil)")
        guard presentedViewController == nil else {
            metal.deliverDialog(files: [], ok: false)
            return
        }
        mode = .open
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = multiple
        picker.delegate = self
        metal.suspendFocus = true
        present(picker, animated: true) { pcLog("open sheet is on screen") }
    }

    /// A file opened from outside the app (Files > Open With, Share).
    private func openFromOutside(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            pcLog("opened from outside: \(url.lastPathComponent), \(data.count) bytes")
            metal.deliverOpened(name: url.lastPathComponent, data: data)
        } catch {
            pcLog("could not read \(url.lastPathComponent): \(error.localizedDescription)")
            message("Couldn’t open the file", error.localizedDescription)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        pcLog("sheet returned \(urls.count) item(s) in mode \(mode)")
        metal.suspendFocus = false
        switch mode {
        case .open:
            var files: [(String, Data)] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    pcLog("read \(data.count) bytes from \(url.lastPathComponent)")
                    files.append((url.lastPathComponent, data))
                } catch {
                    pcLog("read failed: \(error.localizedDescription)")
                    message("Couldn’t open the file", error.localizedDescription)
                }
            }
            metal.deliverDialog(files: files, ok: !files.isEmpty)
        case .export:
            if let u = urls.first, let name = exportingName { register(workName: name, target: u) }
            exportingName = nil
            nextExport()
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pcLog("sheet cancelled in mode \(mode)")
        metal.suspendFocus = false
        switch mode {
        case .open:
            metal.deliverDialog(files: [], ok: false)
        case .export:
            exportingName = nil
            message("Saved inside PhotoCraft only",
                    "Your file is kept in Files › On My iPad › PhotoCraft › Working. Use File › Save As to choose another place.")
            nextExport()
        }
    }

    // MARK: Saving

    /// The app wrote a file into the Working folder: offer it to Apple's Save to Files sheet.
    private func offerToFiles(path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        pcLog("save sheet requested for \(name)")
        exportQueue.append(path)
        if presentedViewController == nil && exportingName == nil { nextExport() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.nextExport() } }
    }

    private func nextExport() {
        guard exportingName == nil, presentedViewController == nil, !exportQueue.isEmpty else {
            if !exportQueue.isEmpty && exportingName == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.nextExport() }
            }
            return
        }
        let path = exportQueue.removeFirst()
        let file = URL(fileURLWithPath: path)
        exportingName = file.lastPathComponent
        mode = .export
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = self
        metal.suspendFocus = true
        present(picker, animated: true)
    }

    /// Remembers the file the person chose, so later saves can update it without asking.
    private func register(workName: String, target url: URL) {
        _ = url.startAccessingSecurityScopedResource()   // kept open so later saves can write
        targets[workName] = url
        lastCopied[workName] = Date()
        pcLog("silent saves of \(workName) will update \(url.lastPathComponent)")
    }

    /// Copies each working copy that changed since the last copy to the file the person chose.
    private func mirrorWorkingCopies() {
        guard let folder = workingFolder else { return }
        for (name, url) in targets {
            let work = folder.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: work.path),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            if modified <= (lastCopied[name] ?? .distantPast) { continue }
            guard let data = try? Data(contentsOf: work) else { continue }

            var coordError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
                do { try data.write(to: writeURL) } catch { writeError = error }
            }
            if let e = (coordError as Error?) ?? writeError {
                pcLog("could not update \(name): \(e.localizedDescription)")
                targets[name] = nil
                message("Couldn’t update “\(url.lastPathComponent)”",
                        "Your changes are kept in Files › On My iPad › PhotoCraft › Working. Use Save As to save a copy where you want it.\n\n\(e.localizedDescription)")
            } else {
                lastCopied[name] = modified
                pcLog("updated \(url.lastPathComponent) (\(data.count) bytes)")
            }
        }
    }

    // MARK: Messages

    /// Shown a moment later, so it still appears while a picker is closing.
    private func message(_ title: String, _ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            let a = UIAlertController(title: title, message: text, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(a, animated: true)
        }
    }
}
