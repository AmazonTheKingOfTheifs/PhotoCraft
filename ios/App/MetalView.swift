import UIKit
import QuartzCore

/// The drawing surface. Catches the Apple Pencil, fingers, the pointer, scrolling, pinching and
/// the keyboard, and hands them to the Rust core.
///
/// Palm rejection works like Procreate's: while the Pencil touches the screen or hovers over it
/// (and for a moment after), finger touches are ignored completely.
final class MetalView: UIView, UIKeyInput, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {

    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    // Hooks the view controller fills in.
    var onOpenDialog: ((Bool) -> Void)?
    var onExport: ((String) -> Void)?
    var onOpenURL: ((String) -> Void)?
    var onCopyText: ((String) -> Void)?
    /// True while a picker or alert is showing, so the view doesn't grab the keyboard back.
    var suspendFocus = false

    private var handle: UnsafeMutableRawPointer?
    private var startFailed = false
    private var link: CADisplayLink?
    private var softKeyboard = false
    private let emptyInput = UIView(frame: .zero)
    private var activeTouch: UITouch?
    private var pointerButton: Int32 = 0
    private var held: (hid: UInt32, mods: UInt32, text: String?, start: CFTimeInterval, last: CFTimeInterval)?

    // Interface size (1.0 is the normal size of the desktop app).
    private var uiScale: Float = 1.3
    private static let scaleKey = "PhotoCraftUIScale"

    // Apple Pencil and palm rejection.
    private var pencilTouch: UITouch?
    private var pencilHovering = false
    private var pencilLastSeen: CFTimeInterval = 0
    /// How long after the Pencil leaves that fingers are still ignored.
    private let palmGrace: CFTimeInterval = 0.45
    private var eraserOn = false

    // Fingers: one finger acts like the pointer, two or more are gestures.
    private var directTouches = Set<UITouch>()
    private var ignoredTouches = Set<UITouch>()
    private var fingerTouch: UITouch?
    private var fingerStart = CGPoint.zero
    private var fingerStartTime: TimeInterval = 0
    private var fingerPressed = false
    private var longPressFired = false

    /// True while the Pencil is touching, hovering, or has only just left the screen.
    private var pencilNear: Bool {
        pencilTouch != nil || pencilHovering || (CACurrentMediaTime() - pencilLastSeen) < palmGrace
    }

    // UITextInputTraits (no autocorrect while typing)
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        setupGestures()
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MetalView, _) in
            view.pushTheme()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        link?.invalidate()
        if let h = handle { pc_destroy(h) }
    }

    // MARK: Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            ensureHandle()
            if link == nil {
                let l = CADisplayLink(target: self, selector: #selector(tick))
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
                l.add(to: .main, forMode: .common)
                link = l
            }
        } else {
            link?.invalidate()
            link = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ensureHandle()
        if let h = handle {
            let s = traitCollection.displayScale
            pc_resize(h, UInt32(max(1, bounds.width * s)), UInt32(max(1, bounds.height * s)), Float(s))
        }
    }

    private func ensureHandle() {
        guard handle == nil, !startFailed, window != nil, bounds.width > 1, bounds.height > 1 else { return }
        let s = traitCollection.displayScale
        contentScaleFactor = s
        metalLayer.contentsScale = s
        let layerPtr = Unmanaged.passUnretained(metalLayer).toOpaque()
        handle = pc_create(layerPtr, UInt32(bounds.width * s), UInt32(bounds.height * s), Float(s), makeCallbacks())
        if handle == nil {
            startFailed = true
        } else {
            pushTheme()
            let saved = UserDefaults.standard.float(forKey: MetalView.scaleKey)
            uiScale = saved > 0 ? saved : autoScale()
            pc_set_ui_scale(handle, uiScale)
        }
    }

    /// Smaller iPads get a larger interface, so buttons are easy to hit with the Pencil.
    private func autoScale() -> Float {
        let size = window?.windowScene?.screen.bounds.size ?? CGSize(width: 834, height: 1194)
        let short = Float(min(size.width, size.height))
        return max(1.15, min(1.5, 1.15 + (1100 - short) / 1000))
    }

    /// Larger or smaller interface (⌘⌃= and ⌘⌃−), or back to the automatic size.
    func adjustUIScale(delta: Float?, reset: Bool) {
        guard let h = handle else { return }
        if reset {
            UserDefaults.standard.removeObject(forKey: MetalView.scaleKey)
            uiScale = autoScale()
        } else if let d = delta {
            uiScale = max(0.8, min(2.4, ((uiScale + d) * 100).rounded() / 100))
            UserDefaults.standard.set(uiScale, forKey: MetalView.scaleKey)
        }
        pc_set_ui_scale(h, uiScale)
    }

    private func pushTheme() {
        guard let h = handle else { return }
        pc_set_dark(h, traitCollection.userInterfaceStyle == .dark ? 1 : 0)
    }

    func saveState() { if let h = handle { pc_save_state(h) } }
    func setFocused(_ focused: Bool) { if let h = handle { pc_set_focused(h, focused ? 1 : 0) } }

    @objc private func tick() {
        guard let h = handle else { return }
        if !suspendFocus && !isFirstResponder { _ = becomeFirstResponder() }
        repeatHeldKey()
        let flags = pc_frame(h)
        let wants = (flags & 2) != 0
        if wants != softKeyboard {
            softKeyboard = wants
            reloadInputViews()
        }
    }

    // MARK: Callbacks from Rust

    fileprivate static func from(_ p: UnsafeMutableRawPointer?) -> MetalView? {
        p.map { Unmanaged<MetalView>.fromOpaque($0).takeUnretainedValue() }
    }

    private func makeCallbacks() -> PCCallbacks {
        let me = Unmanaged.passUnretained(self).toOpaque()
        return PCCallbacks(
            user: me,
            open_dialog: { u, multiple in
                guard let v = MetalView.from(u) else { return }
                DispatchQueue.main.async { v.onOpenDialog?(multiple != 0) }
            },
            export_file: { u, path in
                guard let v = MetalView.from(u), let path = path else { return }
                let s = String(cString: path)
                DispatchQueue.main.async { v.onExport?(s) }
            },
            open_url: { u, url in
                guard let v = MetalView.from(u), let url = url else { return }
                let s = String(cString: url)
                DispatchQueue.main.async { v.onOpenURL?(s) }
            },
            copy_text: { u, text in
                guard let v = MetalView.from(u), let text = text else { return }
                let s = String(cString: text)
                DispatchQueue.main.async { v.onCopyText?(s) }
            }
        )
    }

    // MARK: Results from the view controller

    /// A file arrived from outside (Files, "Open in").
    func deliverOpened(name: String, data: Data) {
        guard let h = handle else { return }
        name.withCString { n in
            data.withUnsafeBytes { raw in
                pc_open_file(h, n, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
        }
    }

    /// The Open sheet finished with these files (or none, when cancelled).
    func deliverDialog(files: [(String, Data)], ok: Bool) {
        guard let h = handle else { return }
        for (name, data) in files {
            name.withCString { n in
                data.withUnsafeBytes { raw in
                    pc_dialog_file(h, n, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
                }
            }
        }
        pc_dialog_end(h, ok ? 1 : 0)
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { softKeyboard ? nil : emptyInput }

    override func resignFirstResponder() -> Bool {
        held = nil
        return super.resignFirstResponder()
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard let h = handle else { return }
        if text == "\n" {
            pc_key(h, 0x28, 1, 0, 0)
            pc_key(h, 0x28, 0, 0, 0)
        } else {
            text.withCString { pc_text(h, $0) }
        }
    }

    func deleteBackward() {
        guard let h = handle else { return }
        pc_key(h, 0x2A, 1, 0, 0)
        pc_key(h, 0x2A, 0, 0, 0)
    }

    private func modBits(_ f: UIKeyModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.shift) { m |= 1 }
        if f.contains(.control) { m |= 2 }
        if f.contains(.alternate) { m |= 4 }
        if f.contains(.command) { m |= 8 }
        return m
    }

    /// Only real typing keys type text: letters, digits, punctuation, space and the keypad.
    /// Arrows, Return, Tab, Escape, F-keys and the like are key presses, never text.
    private func typesText(_ hid: UInt32) -> Bool {
        if hid >= 0x04 && hid <= 0x27 { return true }                 // letters and digits
        if hid >= 0x2C && hid <= 0x38 { return true }                 // space and punctuation
        if hid >= 0x54 && hid <= 0x63 && hid != 0x58 { return true }  // keypad (not its Enter)
        return false
    }

    private func printable(_ s: String) -> String? {
        guard !s.isEmpty else { return nil }
        let ok = s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
        return ok ? s : nil
    }

    /// ⌘C, ⌘X and ⌘V go through the iPad's clipboard.
    private func clipboardShortcut(hid: UInt32, mods: UInt32) -> Bool {
        guard mods == 8, let h = handle else { return false }
        switch hid {
        case 0x06: pc_copy(h); return true
        case 0x1B: pc_cut(h); return true
        case 0x19:
            let s = UIPasteboard.general.string ?? ""
            s.withCString { pc_paste(h, $0) }
            return true
        default: return false
        }
    }

    private func handlePress(_ press: UIPress, down: Bool) -> Bool {
        guard let key = press.key, let h = handle else { return false }
        let hid = UInt32(key.keyCode.rawValue)
        if hid >= 0xE0 && hid <= 0xE7 { return true }   // a modifier key on its own
        let mods = modBits(key.modifierFlags)
        if down {
            if clipboardShortcut(hid: hid, mods: mods) { return true }
            pc_key(h, hid, 1, 0, mods)
            var text: String? = nil
            if typesText(hid) && mods & (8 | 2) == 0 { text = printable(key.characters) }
            if let t = text { t.withCString { pc_text(h, $0) } }
            let now = CACurrentMediaTime()
            held = (hid, mods, text, now, now)
        } else {
            pc_key(h, hid, 0, 0, mods)
            if held?.hid == hid { held = nil }
        }
        return true
    }

    private func repeatHeldKey() {
        guard let k = held, let h = handle else { return }
        let now = CACurrentMediaTime()
        if now - k.start > 0.4 && now - k.last > 0.035 {
            pc_key(h, k.hid, 1, 1, k.mods)
            if let t = k.text { t.withCString { pc_text(h, $0) } }
            held?.last = now
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for p in presses where !handlePress(p, down: true) { rest.insert(p) }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for p in presses where !handlePress(p, down: false) { rest.insert(p) }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        held = nil
        super.pressesCancelled(presses, with: event)
    }

    // ⌘ shortcuts are claimed ahead of the system so ⌘Z, ⌘S, ⌘J and friends reach the app.
    private static let commandKeys: [UIKeyCommand] = {
        let letters = Array("abcdefgijklmnoprstuvxyz0123456789-=[];',./\\`").map { String($0) }
        let specials = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow,
                        UIKeyCommand.inputRightArrow, UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown,
                        UIKeyCommand.inputHome, UIKeyCommand.inputEnd]
        let mods: [UIKeyModifierFlags] = [.command, [.command, .shift], [.command, .alternate], [.command, .shift, .alternate]]
        var list: [UIKeyCommand] = []
        for input in letters + specials {
            for m in mods {
                let c = UIKeyCommand(input: input, modifierFlags: m, action: #selector(MetalView.commandKey(_:)))
                c.wantsPriorityOverSystemBehavior = true
                list.append(c)
            }
        }
        return list
    }()

    override var keyCommands: [UIKeyCommand]? { MetalView.commandKeys }

    private static func hid(for s: String) -> UInt32? {
        switch s {
        case UIKeyCommand.inputUpArrow: return 0x52
        case UIKeyCommand.inputDownArrow: return 0x51
        case UIKeyCommand.inputLeftArrow: return 0x50
        case UIKeyCommand.inputRightArrow: return 0x4F
        case UIKeyCommand.inputPageUp: return 0x4B
        case UIKeyCommand.inputPageDown: return 0x4E
        case UIKeyCommand.inputHome: return 0x4A
        case UIKeyCommand.inputEnd: return 0x4D
        default: break
        }
        guard s.unicodeScalars.count == 1, let u = s.lowercased().unicodeScalars.first else { return nil }
        switch u {
        case "a"..."z": return 0x04 + (u.value - 97)
        case "1"..."9": return 0x1E + (u.value - 49)
        case "0": return 0x27
        case "-": return 0x2D
        case "=": return 0x2E
        case "[": return 0x2F
        case "]": return 0x30
        case "\\": return 0x31
        case ";": return 0x33
        case "'": return 0x34
        case "`": return 0x35
        case ",": return 0x36
        case ".": return 0x37
        case "/": return 0x38
        default: return nil
        }
    }

    @objc func commandKey(_ cmd: UIKeyCommand) {
        guard let h = handle, let input = cmd.input, let hid = MetalView.hid(for: input) else { return }
        let mods = modBits(cmd.modifierFlags)
        if clipboardShortcut(hid: hid, mods: mods) { return }
        pc_key(h, hid, 1, 0, mods)
        pc_key(h, hid, 0, 0, mods)
    }

    /// A key press and release, like a shortcut typed on a keyboard.
    private func tapKey(_ hid: UInt32, mods: UInt32 = 0) {
        guard let h = handle else { return }
        pc_key(h, hid, 1, 0, mods)
        pc_key(h, hid, 0, 0, mods)
    }

    // MARK: Apple Pencil buttons

    /// Double tap on the Pencil: switch between the Brush (B) and the Eraser (E).
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        eraserOn.toggle()
        tapKey(eraserOn ? 0x08 : 0x05)
    }

    /// Squeeze on the Pencil Pro: the Eyedropper (I).
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended {
            eraserOn = false
            tapKey(0x0C)
        }
    }

    // MARK: Gestures

    private func setupGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverMoved(_:)))
        hover.delegate = self
        addGestureRecognizer(hover)

        let wheel = UIPanGestureRecognizer(target: self, action: #selector(pointerScroll(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        wheel.cancelsTouchesInView = false
        wheel.delegate = self
        addGestureRecognizer(wheel)

        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(twoFingerScroll(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.allowedTouchTypes = direct
        twoFinger.cancelsTouchesInView = false
        twoFinger.delegate = self
        addGestureRecognizer(twoFinger)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.allowedTouchTypes = direct
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.55
        longPress.allowableMovement = 12
        longPress.numberOfTouchesRequired = 1
        longPress.allowedTouchTypes = direct
        longPress.cancelsTouchesInView = false
        longPress.delegate = self
        addGestureRecognizer(longPress)

        // Two fingers tap: Undo. Three fingers tap: Redo.
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        twoTap.allowedTouchTypes = direct
        twoTap.cancelsTouchesInView = false
        twoTap.delegate = self
        addGestureRecognizer(twoTap)

        let threeTap = UITapGestureRecognizer(target: self, action: #selector(threeFingerTap(_:)))
        threeTap.numberOfTouchesRequired = 3
        threeTap.allowedTouchTypes = direct
        threeTap.cancelsTouchesInView = false
        threeTap.delegate = self
        addGestureRecognizer(threeTap)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// Palm rejection: no finger gesture starts while the Pencil is near.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.type == .pencil { return false }
        if touch.type == .direct && pencilNear { return false }
        return true
    }

    @objc private func hoverMoved(_ g: UIHoverGestureRecognizer) {
        guard let h = handle else { return }
        // An Apple Pencil hovering reports a distance from the glass; a mouse or trackpad does not.
        let isPencil = g.zOffset > 0
        switch g.state {
        case .began, .changed:
            let p = g.location(in: self)
            if isPencil {
                pencilHovering = true
                pencilLastSeen = CACurrentMediaTime()
                if !ignoredTouches.isEmpty || fingerTouch != nil { cancelFinger() }
            }
            pc_pointer_moved(h, Float(p.x), Float(p.y))
        case .ended, .cancelled:
            if pencilHovering {
                pencilHovering = false
                pencilLastSeen = CACurrentMediaTime()
            }
            pc_pointer_gone(h)
        default: break
        }
    }

    @objc private func pointerScroll(_ g: UIPanGestureRecognizer) {
        guard let h = handle, g.state != .ended, g.state != .cancelled, g.state != .failed else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if t != .zero { pc_scroll(h, Float(t.x), Float(t.y), modBits(g.modifierFlags)) }
    }

    @objc private func twoFingerScroll(_ g: UIPanGestureRecognizer) {
        guard let h = handle, g.state != .ended, g.state != .cancelled, g.state != .failed else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if t != .zero { pc_scroll(h, Float(t.x), Float(t.y), 0) }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard let h = handle else { return }
        switch g.state {
        case .changed:
            let p = g.location(in: self)
            pc_zoom(h, Float(g.scale), Float(p.x), Float(p.y))
            g.scale = 1
        case .ended, .cancelled:
            pc_pointer_gone(h)
        default: break
        }
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, fingerTouch != nil, !fingerPressed else { return }
        longPressFired = true
        syntheticClick(g.location(in: self), button: 1, mods: 0)
    }

    @objc private func twoFingerTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, !pencilNear else { return }
        tapKey(0x1D, mods: 8)        // ⌘Z
    }

    @objc private func threeFingerTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, !pencilNear else { return }
        tapKey(0x1D, mods: 8 | 1)    // ⇧⌘Z
    }

    // MARK: Pencil, pointer and finger touches

    /// A press and release a moment apart, so the app sees a real click.
    private func syntheticClick(_ p: CGPoint, button: Int32, mods: UInt32) {
        guard let h = handle else { return }
        let x = Float(p.x), y = Float(p.y)
        pc_pointer_moved(h, x, y)
        pc_pointer_button(h, x, y, button, 1, mods)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self = self, let h = self.handle else { return }
            pc_pointer_button(h, x, y, button, 0, mods)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                guard let self = self, let h = self.handle else { return }
                pc_pointer_gone(h)
            }
        }
    }

    /// Drops a finger that was acting as the pointer (a second finger or the Pencil arrived).
    private func cancelFinger() {
        if fingerPressed, let t = fingerTouch, let h = handle {
            let p = t.location(in: self)
            pc_pointer_button(h, Float(p.x), Float(p.y), 0, 0, 0)
            pc_pointer_gone(h)
        }
        fingerTouch = nil
        fingerPressed = false
    }

    /// Sends the Pencil's position, pressure, tilt and roll (all the in-between samples too).
    private func sendPen(_ touch: UITouch, phase: Int32, event: UIEvent?, mods: UInt32) {
        guard let h = handle else { return }
        var samples: [UITouch] = [touch]
        if phase == 1, let more = event?.coalescedTouches(for: touch), !more.isEmpty { samples = more }
        for c in samples {
            let p = c.location(in: self)
            let maxForce = c.maximumPossibleForce
            let pressure: Float = maxForce > 0 ? Float(c.force / maxForce) : 1
            let altitude = Double(c.altitudeAngle)
            let az = c.azimuthUnitVector(in: self)
            let upright = max(sin(altitude), 0.0001)
            let flat = cos(altitude)
            let tiltX = Float(atan2(Double(az.dx) * flat, upright) * 180 / Double.pi)
            let tiltY = Float(atan2(Double(az.dy) * flat, upright) * 180 / Double.pi)
            var roll: Float = 0
            if #available(iOS 17.5, *) { roll = Float(c.rollAngle * 180 / CGFloat.pi) }
            pc_pen(h, Float(p.x), Float(p.y), phase, pressure, tiltX, tiltY, roll, mods)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let h = handle else { return }
        let mods = modBits(event?.modifierFlags ?? [])
        for t in touches {
            let p = t.location(in: self)
            switch t.type {
            case .pencil:
                // Anything already resting on the screen is a palm.
                for d in directTouches { ignoredTouches.insert(d) }
                directTouches.removeAll()
                cancelFinger()
                pencilTouch = t
                pencilLastSeen = CACurrentMediaTime()
                sendPen(t, phase: 0, event: event, mods: mods)
            case .indirectPointer:
                pointerButton = (event?.buttonMask.contains(.secondary) ?? false) ? 1 : 0
                pc_pointer_moved(h, Float(p.x), Float(p.y))
                pc_pointer_button(h, Float(p.x), Float(p.y), pointerButton, 1, mods)
            default:
                if pencilNear {
                    ignoredTouches.insert(t)
                    continue
                }
                directTouches.insert(t)
                if directTouches.count == 1 {
                    fingerTouch = t
                    fingerStart = p
                    fingerStartTime = t.timestamp
                    fingerPressed = false
                    longPressFired = false
                } else {
                    // A second finger means scrolling, pinching or a tap gesture, never a press.
                    cancelFinger()
                }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let h = handle else { return }
        let mods = modBits(event?.modifierFlags ?? [])
        for t in touches {
            let p = t.location(in: self)
            switch t.type {
            case .pencil:
                if t === pencilTouch { sendPen(t, phase: 1, event: event, mods: mods) }
            case .indirectPointer:
                pc_pointer_moved(h, Float(p.x), Float(p.y))
            default:
                guard t === fingerTouch else { continue }
                if !fingerPressed {
                    let dx = p.x - fingerStart.x, dy = p.y - fingerStart.y
                    if dx * dx + dy * dy > 64 && !longPressFired {
                        // The finger moved: now it is a drag, starting where it first landed.
                        fingerPressed = true
                        pc_pointer_moved(h, Float(fingerStart.x), Float(fingerStart.y))
                        pc_pointer_button(h, Float(fingerStart.x), Float(fingerStart.y), 0, 1, mods)
                        pc_pointer_moved(h, Float(p.x), Float(p.y))
                    }
                } else {
                    pc_pointer_moved(h, Float(p.x), Float(p.y))
                }
            }
        }
    }

    private func finish(_ touches: Set<UITouch>, with event: UIEvent?, cancelled: Bool) {
        guard let h = handle else { return }
        let mods = modBits(event?.modifierFlags ?? [])
        for t in touches {
            let p = t.location(in: self)
            ignoredTouches.remove(t)
            switch t.type {
            case .pencil:
                if t === pencilTouch {
                    sendPen(t, phase: cancelled ? 3 : 2, event: event, mods: mods)
                    pencilTouch = nil
                    pencilLastSeen = CACurrentMediaTime()
                }
            case .indirectPointer:
                pc_pointer_button(h, Float(p.x), Float(p.y), pointerButton, 0, mods)
            default:
                directTouches.remove(t)
                guard t === fingerTouch else { continue }
                if fingerPressed {
                    pc_pointer_button(h, Float(p.x), Float(p.y), 0, 0, mods)
                    pc_pointer_gone(h)
                } else if !cancelled && !longPressFired && !pencilNear && (t.timestamp - fingerStartTime) < 0.5 {
                    // A quick tap: one click where the finger landed.
                    syntheticClick(fingerStart, button: 0, mods: mods)
                }
                fingerTouch = nil
                fingerPressed = false
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, with: event, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, with: event, cancelled: true) }
}
