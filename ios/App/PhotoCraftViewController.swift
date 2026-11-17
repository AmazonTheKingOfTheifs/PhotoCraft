import UIKit
import UniformTypeIdentifiers
import PhotosUI

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

/// Owns the drawing view and everything that needs Apple's own screens: the import chooser
/// (Photos or Files), the Files sheets, alerts, the font picker, and the bar of big buttons.
///
/// Files are never copied. A file opened from Files is read and saved in its own place, and
/// Save As asks Files where to put the new file. Nothing is kept in a hidden folder.
final class PhotoCraftViewController: UIViewController, UIDocumentPickerDelegate, UIFontPickerViewControllerDelegate, PHPickerViewControllerDelegate {

    private let metal = MetalView()

    private enum Mode { case open, save }
    private var mode: Mode = .open
    /// True when the Open sheet hands back the files themselves (copies), false when it opens them in place.
    private var openAsCopy = false
    /// The empty file Save to Files moves into place.
    private var savePlaceholder: URL?

    private let bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private var fingerButton: UIButton?
    private var barPlaced = false
    private static let barKey = "PhotoCraftBarPosition"

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

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

        metal.onOpenDialog = { [weak self] multiple, pictures in self?.showImportChooser(multiple: multiple, pictures: pictures) }
        metal.onSaveDialog = { [weak self] name in self?.showSaveSheet(name: name) }
        metal.onOpenURL = { url in
            guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return }
            UIApplication.shared.open(u)
        }
        metal.onCopyText = { UIPasteboard.general.string = $0 }

        buildBar()

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
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
    }

    // MARK: The bar of big buttons

    private func makeButton(_ symbol: String, _ label: String, _ action: Selector?) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        let b = UIButton(configuration: config)
        if let action = action { b.addTarget(self, action: action, for: .touchUpInside) }
        b.accessibilityLabel = label
        return b
    }

    private func buildBar() {
        let undo = makeButton("arrow.uturn.backward", "Undo", #selector(tapUndo))
        let redo = makeButton("arrow.uturn.forward", "Redo", #selector(tapRedo))
        let fit = makeButton("arrow.up.left.and.arrow.down.right", "Fit on screen", #selector(tapFit))
        let finger = makeButton("hand.draw", "Draw with finger", #selector(tapFinger))
        fingerButton = finger
        let size = makeButton("textformat.size", "Interface size", nil)
        size.showsMenuAsPrimaryAction = true
        size.menu = UIMenu(title: "Interface size", children: [
            UIAction(title: "Larger", image: UIImage(systemName: "plus")) { [weak self] _ in self?.metal.adjustUIScale(delta: 0.1, reset: false) },
            UIAction(title: "Smaller", image: UIImage(systemName: "minus")) { [weak self] _ in self?.metal.adjustUIScale(delta: -0.1, reset: false) },
            UIAction(title: "Automatic", image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in self?.metal.adjustUIScale(delta: nil, reset: true) }
        ])
        let pencil = makeButton("pencil.tip", "Pencil pressure", nil)
        pencil.showsMenuAsPrimaryAction = true
        pencil.menu = UIMenu(title: "Pencil pressure", children: [
            UIAction(title: "Softer (light touch is enough)", image: UIImage(systemName: "feather")) { [weak self] _ in
                self?.metal.adjustPressure(by: 0.3); self?.toast("Pencil: softer")
            },
            UIAction(title: "Firmer (needs more pressure)", image: UIImage(systemName: "hand.point.down")) { [weak self] _ in
                self?.metal.adjustPressure(by: -0.3); self?.toast("Pencil: firmer")
            },
            UIAction(title: "Reset", image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in
                self?.metal.adjustPressure(by: 0, reset: true); self?.toast("Pencil: default")
            }
        ])

        let stack = UIStackView(arrangedSubviews: [undo, redo, fit, finger, pencil, size])
        stack.axis = .horizontal
        stack.spacing = 0
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bar.contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -6)
        ])
        bar.layer.cornerRadius = 22
        bar.clipsToBounds = true
        bar.alpha = 0.92
        view.addSubview(bar)
        bar.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragBar(_:))))
        refreshFingerButton()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = bar.contentView.systemLayoutSizeFitting(CGSize(width: view.bounds.width, height: 80),
                                                           withHorizontalFittingPriority: .fittingSizeLevel,
                                                           verticalFittingPriority: .fittingSizeLevel)
        let w = max(size.width + 12, 200), h = max(size.height + 8, 52)
        if !barPlaced {
            barPlaced = true
            var cx = 12 + w / 2
            var cy = view.bounds.height - view.safeAreaInsets.bottom - h / 2 - 48
            if let saved = UserDefaults.standard.array(forKey: PhotoCraftViewController.barKey) as? [Double], saved.count == 2 {
                cx = CGFloat(saved[0]) * view.bounds.width
                cy = CGFloat(saved[1]) * view.bounds.height
            }
            bar.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            bar.center = CGPoint(x: cx, y: cy)
        } else {
            bar.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        }
        keepBarOnScreen()
        view.bringSubviewToFront(bar)
    }

    private func keepBarOnScreen() {
        let b = view.bounds, s = bar.bounds.size
        let cx = min(max(bar.center.x, s.width / 2 + 4), b.width - s.width / 2 - 4)
        let cy = min(max(bar.center.y, s.height / 2 + 4), b.height - s.height / 2 - 4)
        bar.center = CGPoint(x: cx, y: cy)
    }

    @objc private func dragBar(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        bar.center = CGPoint(x: bar.center.x + t.x, y: bar.center.y + t.y)
        g.setTranslation(.zero, in: view)
        keepBarOnScreen()
        if g.state == .ended {
            UserDefaults.standard.set([Double(bar.center.x / view.bounds.width), Double(bar.center.y / view.bounds.height)],
                                      forKey: PhotoCraftViewController.barKey)
        }
    }

    @objc private func tapUndo() { metal.undo() }
    @objc private func tapRedo() { metal.redo() }
    @objc private func tapFit() { metal.fitOnScreen() }

    @objc private func tapFinger() {
        metal.setFingersDraw(!metal.fingersDraw)
        refreshFingerButton()
        toast(metal.fingersDraw ? "Finger drawing on" : "Finger drawing off: fingers pan and zoom")
    }

    private func refreshFingerButton() {
        fingerButton?.configuration?.baseForegroundColor = metal.fingersDraw ? .systemGreen : .white
    }

    private func toast(_ text: String) {
        let label = UILabel()
        label.text = "  \(text)  "
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.backgroundColor = UIColor(white: 0, alpha: 0.75)
        label.layer.cornerRadius = 16
        label.clipsToBounds = true
        label.textAlignment = .center
        label.sizeToFit()
        label.frame = label.frame.insetBy(dx: -8, dy: -10)
        label.center = CGPoint(x: view.bounds.midX, y: bar.frame.minY - 34)
        view.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 1.4, options: [], animations: { label.alpha = 0 }) { _ in label.removeFromSuperview() }
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

    // MARK: Importing: Photos or Files

    /// Asks where to import from (Photos or Files), then opens the matching Apple sheet.
    private func showImportChooser(multiple: Bool, pictures: Bool) {
        pcLog("import requested; several: \(multiple); pictures: \(pictures); already presenting: \(presentedViewController != nil)")
        guard presentedViewController == nil else {
            metal.deliverDialog(files: [], paths: [], ok: false)
            return
        }
        if !pictures {
            showFilesOpen(multiple: multiple)
            return
        }
        let sheet = UIAlertController(title: "Import from", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Photos", style: .default) { [weak self] _ in self?.showPhotos(multiple: multiple) })
        sheet.addAction(UIAlertAction(title: "Files", style: .default) { [weak self] _ in self?.showFilesOpen(multiple: multiple) })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.metal.suspendFocus = false
            self?.metal.deliverDialog(files: [], paths: [], ok: false)
        })
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        metal.suspendFocus = true
        present(sheet, animated: true)
    }

    /// Apple's Open sheet. One file is opened where it is (no copy); several are copied in.
    private func showFilesOpen(multiple: Bool) {
        mode = .open
        openAsCopy = multiple
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: multiple)
        picker.allowsMultipleSelection = multiple
        picker.delegate = self
        metal.suspendFocus = true
        present(picker, animated: true) { pcLog("open sheet is on screen") }
    }

    private func showPhotos(multiple: Bool) {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = multiple ? 0 : 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        metal.suspendFocus = true
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        metal.suspendFocus = false
        if results.isEmpty {
            metal.deliverDialog(files: [], paths: [], ok: false)
            return
        }
        var found: [(Int, String, Data)] = []
        let lock = NSLock()
        let group = DispatchGroup()
        let keep = ["jpg", "jpeg", "png", "tif", "tiff", "webp", "gif"]
        for (i, result) in results.enumerated() {
            let provider = result.itemProvider
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                defer { group.leave() }
                guard let data = data else {
                    pcLog("photo \(i + 1) could not be read: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                let type = provider.registeredTypeIdentifiers.first.flatMap { UTType($0) }
                var ext = type?.preferredFilenameExtension?.lowercased() ?? "jpg"
                var out = data
                if !keep.contains(ext) {
                    // HEIC and other Apple formats: PhotoCraft gets a lossless PNG.
                    if let image = UIImage(data: data), let png = image.pngData() {
                        out = png
                        ext = "png"
                    }
                }
                let base = provider.suggestedName ?? "Photo \(i + 1)"
                lock.lock()
                found.append((i, "\(base).\(ext)", out))
                lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let files = found.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
            pcLog("photos: \(files.count) of \(results.count) read")
            self?.metal.deliverDialog(files: files, paths: [], ok: !files.isEmpty)
        }
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

    // MARK: Saving

    /// Apple's Save to Files sheet. The new file is created where you choose, and PhotoCraft
    /// then writes straight into it.
    private func showSaveSheet(name: String, attempt: Int = 0) {
        if presentedViewController != nil {
            if attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showSaveSheet(name: name, attempt: attempt + 1) }
            } else {
                metal.deliverSaveDialog(path: nil)
            }
            return
        }
        pcLog("save sheet requested for \(name)")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoCraftSave-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: file.path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            pcLog("could not prepare the save sheet: \(error.localizedDescription)")
            message("Couldn’t save", error.localizedDescription)
            metal.deliverSaveDialog(path: nil)
            return
        }
        savePlaceholder = file
        mode = .save
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: false)
        picker.delegate = self
        metal.suspendFocus = true
        present(picker, animated: true)
    }

    private func cleanUpPlaceholder() {
        if let file = savePlaceholder {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        savePlaceholder = nil
    }

    // MARK: Picker results

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        pcLog("sheet returned \(urls.count) item(s) in mode \(mode)")
        metal.suspendFocus = false
        switch mode {
        case .open:
            if openAsCopy {
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
                metal.deliverDialog(files: files, paths: [], ok: !files.isEmpty)
            } else {
                var paths: [String] = []
                for url in urls {
                    FileAccess.shared.remember(url)
                    FileAccess.shared.prepareForReading(url)
                    paths.append(url.path)
                }
                metal.deliverDialog(files: [], paths: paths, ok: !paths.isEmpty)
            }
        case .save:
            if let url = urls.first {
                FileAccess.shared.remember(url)
                pcLog("save place chosen: \(url.path)")
                metal.deliverSaveDialog(path: url.path)
            } else {
                metal.deliverSaveDialog(path: nil)
            }
            cleanUpPlaceholder()
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pcLog("sheet cancelled in mode \(mode)")
        metal.suspendFocus = false
        switch mode {
        case .open:
            metal.deliverDialog(files: [], paths: [], ok: false)
        case .save:
            metal.deliverSaveDialog(path: nil)
            cleanUpPlaceholder()
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
