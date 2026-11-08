//
// MouseZoomOnMac — pinch-zoom (magnification) gesture helper for external mice on macOS.
//
// Triggers:
//   - Hold a keyboard modifier (default: Option) + scroll wheel -> pinch zoom in/out
//   - Hold a mouse side button (default: back=4 / forward=5) + scroll wheel -> pinch zoom
//   - Release trigger -> gesture ends
//   - Plain scroll (no trigger) passes through untouched -> panning (e.g. in a zoomed view)
//
// Permissions: System Settings > Privacy & Security > Accessibility (and Input Monitoring)
//

import Cocoa
import ApplicationServices

// MARK: - Constants (undocumented, from Calftrail Touch / TouchSimulator.m)

private let kEventTypeGesture: CGEventType = CGEventType(rawValue: 29)! // NSEventTypeGesture
private let kFieldHIDType = CGEventField(rawValue: 110)!               // HID event type
private let kFieldMagnification = CGEventField(rawValue: 113)!         // magnification amount
private let kFieldPhase = CGEventField(rawValue: 132)!                 // gesture phase
private let kHIDTypeZoom: Int64 = 8 // kIOHIDEventTypeZoom
private let kPhaseBegan: Int64 = 1
private let kPhaseChanged: Int64 = 2
private let kPhaseEnded: Int64 = 4

// From MMF v3 Scroll.m: Chromium-based browsers detected by bundle-id substring
private let chromiumBundleIDs = [
    "com.google.Chrome",
    "org.chromium.Chromium",
    "company.thebrowser.Browser", // Arc
    "com.operasoftware.Opera",
    "com.microsoft.edgemac",
    "com.vivaldi.Vivaldi",
    "com.brave.Browser",
    "com.valvesoftware.steam",
]

// CGMouseButton values (1-based): left=1, right=2, middle=3, back=4, forward=5
private let kMouseButtonBack = 4
private let kMouseButtonForward = 5

// MARK: - Config

struct Config {
    var modifier: NSEvent.ModifierFlags? = .option
    var buttons: Set<Int> = [kMouseButtonBack, kMouseButtonForward]
    var scale: Double = 800.0 // MMF v3: delta = (dx+dy)/800
    var chromiumBurst: Bool = true
    var verbose: Bool = false
    var verify: Bool = false // second tap: monitor gesture events, read back field values
    var logFile: String? = nil // tee all log output to a file
}

func modifierName(_ flags: NSEvent.ModifierFlags?) -> String {
    guard let flags = flags else { return "(none)" }
    switch flags {
    case .option: return "Option (⌥)"
    case .command: return "Command (⌘)"
    case .control: return "Control (⌃)"
    case .shift: return "Shift (⇧)"
    default: return "flags \(flags.rawValue)"
    }
}

func parseModifier(_ name: String) -> NSEvent.ModifierFlags? {
    switch name.lowercased() {
    case "option", "alt": return .option
    case "command", "cmd": return .command
    case "control", "ctrl": return .control
    case "shift": return .shift
    case "none": return nil
    default:
        print("error: unknown modifier '\(name)' (option|command|control|shift|none)")
        exit(1)
    }
}

func printHelp() {
    print("""
    MouseZoomOnMac — pinch-zoom for external mice

    USAGE: MouseZoomOnMac [options]
      --modifier=<option|command|control|shift|none>   keyboard trigger (default: option)
      --buttons=<4,5>                                 side-button trigger (4=back, 5=forward)
      --no-buttons                                    disable side-button trigger
      --scale=<n>                                   wheel delta / n (default: 800, MMF v3)
      --no-burst                                    disable the Chromium zoom burst hack
      --verify                                    monitor posted gesture events (debug)
      --log-file=<path>                         tee log output to a file
      -v, --verbose                                 log every event
      -h, --help                                    this help

    Usage: hold trigger + scroll = pinch zoom. Release = end. Plain scroll = pan.
    """)
}

func parseConfig() -> Config {
    var cfg = Config()
    // Normalize --flag=value into --flag value so both forms work
    var args: [String] = []
    for arg in CommandLine.arguments.dropFirst() {
        if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
            args.append(String(arg[..<eq]))
            args.append(String(arg[arg.index(after: eq)...]))
        } else {
            args.append(arg)
        }
    }
    func next(_ flag: String) -> String {
        guard !args.isEmpty else { print("error: missing value for \(flag)"); exit(1) }
        let value = args[0]
        args = Array(args.dropFirst())
        return value
    }
    while !args.isEmpty {
        let arg = args[0]
        args = Array(args.dropFirst())
        switch arg {
        case "--modifier": cfg.modifier = parseModifier(next("--modifier"))
        case "--buttons":
            let parsed: [Int] = next("--buttons").split(separator: ",").compactMap { Int($0) }
            cfg.buttons = Set(parsed)
        case "--no-buttons": cfg.buttons = []
        case "--scale":
            if let sc = Double(next("--scale")) { cfg.scale = sc }
            else { print("error: bad --scale value"); exit(1) }
        case "--no-burst": cfg.chromiumBurst = false
        case "--verify": cfg.verify = true
        case "--log-file": cfg.logFile = next("--log-file")
        case "-v", "--verbose": cfg.verbose = true
        case "-h", "--help": printHelp(); exit(0)
        default:
            print("error: unknown argument \(arg) (see --help)")
            exit(1)
        }
    }
    return cfg
}

// MARK: - Logging

var logFileHandle: FileHandle?

func log(_ message: String) {
    print(message)
    if let logFileHandle {
        if let data = (message + "\n").data(using: .utf8) {
            logFileHandle.write(data)
        }
    }
}

// MARK: - Engine

final class Engine {
    let config: Config
    private var tapPort: CFMachPort?
    private var verifyTapPort: CFMachPort?
    private let bootTime = Date()

    // state
    private var keyHeld = false
    private var pressedButtons: Set<Int> = []
    private var gestureActive = false // Began posted
    private var gestureHappened = false // a non-zero delta was sent
    private var lastActivity = Date.distantPast

    init(_ cfg: Config) { self.config = cfg }

    private var triggerHeld: Bool {
        if config.modifier != nil && keyHeld { return true }
        if !config.buttons.isEmpty && !pressedButtons.isEmpty { return true }
        return false
    }

    func tryStart() -> Bool {
        let scrollMask: CGEventMask = 1 << CGEventType(rawValue: 22)!.rawValue // kCGEventScrollWheel
        let flagsMask: CGEventMask = 1 << CGEventType(rawValue: 12)!.rawValue // kCGEventFlagsChanged
        let downMask: CGEventMask = 1 << CGEventType(rawValue: 10)!.rawValue // kCGEventMouseDown
        let upMask: CGEventMask = 1 << CGEventType(rawValue: 11)!.rawValue // kCGEventMouseUp
        let otherDownMask: CGEventMask = 1 << CGEventType(rawValue: 25)!.rawValue // kCGEventOtherMouseDown
        let otherUpMask: CGEventMask = 1 << CGEventType(rawValue: 26)!.rawValue // kCGEventOtherMouseUp
        let mask: CGEventMask = scrollMask | flagsMask | downMask | upMask | otherDownMask | otherUpMask

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return nil }
            let engine = Unmanaged<Engine>.fromOpaque(refcon).takeUnretainedValue()
            return engine.handle(type: type, event: event)
        }

        guard let tapPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tapPort = tapPort
        let runSource = CFMachPortCreateRunLoopSource(nil, tapPort, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .defaultMode)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runSource, .commonModes)
        CGEvent.tapEnable(tap: tapPort, enable: true)

        // Safety: auto-end the gesture if trigger-release events were missed.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if self.gestureActive, Date().timeIntervalSince(self.lastActivity) > 10 {
                self.endGesture(reason: "timeout")
            }
        }

        if config.verify {
            // Second, passive tap: watches gesture (29) events so we can verify whether
            // the synthetic magnification events are visible to the system at all,
            // and with which field values.
            let verifyCallback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<Engine>.fromOpaque(refcon).takeUnretainedValue()
                engine.verifyGesture(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }
            let verifyMask: CGEventMask = 1 << kEventTypeGesture.rawValue
            if let verifyTapPort = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: verifyMask,
                callback: verifyCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) {
                self.verifyTapPort = verifyTapPort
                let verifySource = CFMachPortCreateRunLoopSource(nil, verifyTapPort, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), verifySource, .defaultMode)
                CGEvent.tapEnable(tap: verifyTapPort, enable: true)
                log("verify: gesture monitor tap active")
            } else {
                log("verify: could not create the monitor tap")
            }
        }
        return true
    }

    private func verifyGesture(type: CGEventType, event: CGEvent) {
        let hidType = event.getIntegerValueField(kFieldHIDType)
        let phase = event.getIntegerValueField(kFieldPhase)
        let magnitude = event.getDoubleValueField(kFieldMagnification)
        log(String(format: "[VERIFY] gesture event: HIDType=%lld phase=%lld magnification=%f", hidType, phase, magnitude))
    }

    @discardableResult
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
            verboseLog("tap re-enabled after disable (type \(type.rawValue))")
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            if let mod = config.modifier {
                keyHeld = event.flags.contains(CGEventFlags(rawValue: UInt64(mod.rawValue)))
            }
            let scrollV = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let scrollH = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            verboseLog("scroll v=\(scrollV) h=\(scrollH) keyHeld=\(keyHeld) btns=\(pressedButtons.sorted())")
            return handleScroll(event)
        case CGEventType(rawValue: 10)!, CGEventType(rawValue: 25)!: // mouseDown / otherMouseDown
            let button = Int(event.getIntegerValueField(.mouseEventNumber))
            verboseLog("mouseDown button=\(button)")
            if config.buttons.contains(button) {
                pressedButtons.insert(button)
                return nil // capture: hide from other apps (like MMF)
            }
            return Unmanaged.passUnretained(event)
        case CGEventType(rawValue: 11)!, CGEventType(rawValue: 26)!: // mouseUp / otherMouseUp
            let button = Int(event.getIntegerValueField(.mouseEventNumber))
            verboseLog("mouseUp button=\(button)")
            if config.buttons.contains(button) {
                pressedButtons.remove(button)
                if !triggerHeld { endGesture(reason: "trigger released") }
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            if let mod = config.modifier {
                keyHeld = event.flags.contains(CGEventFlags(rawValue: UInt64(mod.rawValue)))
            }
            verboseLog("flagsChanged -> keyHeld=\(keyHeld)")
            if !triggerHeld { endGesture(reason: "trigger released") }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if let mod = config.modifier {
            keyHeld = event.flags.contains(CGEventFlags(rawValue: UInt64(mod.rawValue)))
        }
        guard triggerHeld else {
            return Unmanaged.passUnretained(event) // pass through -> normal scrolling / panning
        }
        let deltaVertical = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let deltaHorizontal = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        let delta = (deltaVertical + deltaHorizontal) / config.scale // MMF v3: (dx + dy)/800.0
        guard delta != 0 else { return nil } // swallow

        if !gestureActive {
            // MMF v3 approach: the Began event carries the real delta (a zero-delta Began
            // gets ignored by receivers, so we don't waste it).
            gestureActive = true
            verboseLog("pinch begin delta=\(delta)")
            postMagnification(delta, phase: kPhaseBegan)

            // Chromium burst hack (from MMF v3 Scroll.m): Chromium browsers need a ton of
            // zooming deltas before they actually start zooming.
            if config.chromiumBurst, isChromiumApp(underPointer: event.location) {
                var burstDelta = delta
                if burstDelta > 0 { burstDelta += 380.0 / 800.0 } else { burstDelta -= 250.0 / 800.0 }
                postMagnification(burstDelta, phase: kPhaseChanged)
                verboseLog("chromium burst delta=\(burstDelta)")
            }
        } else {
            postMagnification(delta, phase: kPhaseChanged)
        }
        gestureHappened = true
        lastActivity = Date()
        return nil // swallow: the wheel must not scroll natively while pinching
    }

    private func endGesture(reason: String) {
        guard gestureActive else { return }
        if gestureHappened {
            postMagnification(0.0, phase: kPhaseEnded)
            verboseLog("pinch end (\(reason))")
        }
        gestureActive = false
        gestureHappened = false
    }

    // MARK: Output — the "secret" (undocumented CGEvent fields, TouchSimulator.m)

    private func postMagnification(_ magnification: Double, phase: Int64) {
        guard let outEvent = CGEvent(source: nil) else { return }
        outEvent.type = kEventTypeGesture                                       // 29 = NSEventTypeGesture
        outEvent.setIntegerValueField(kFieldHIDType, value: kHIDTypeZoom)               // 110 = 8 -> kIOHIDEventTypeZoom
        outEvent.setIntegerValueField(kFieldPhase, value: phase)                        // 132 = phase
        outEvent.setDoubleValueField(kFieldMagnification, value: magnification)         // 113 = magnification
        outEvent.post(tap: .cghidEventTap)
    }

    // MARK: Chromium detection (bundle id under the mouse pointer, like MMF v3)

    private func isChromiumApp(underPointer point: CGPoint) -> Bool {
        guard let bundleId = bundleIDUnderPointer(point) else { return false }
        if config.verbose { verboseLog("app under pointer: \(bundleId)") }
        return chromiumBundleIDs.contains { bundleId.contains($0) }
    }

    private func bundleIDUnderPointer(_ point: CGPoint) -> String? {
        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for window in windowList {
                guard let bounds = window["kCGWindowBounds"] as? [String: Any],
                      let originX = (bounds["X"] as? NSNumber)?.doubleValue,
                      let originY = (bounds["Y"] as? NSNumber)?.doubleValue,
                      let winWidth = (bounds["Width"] as? NSNumber)?.doubleValue,
                      let winHeight = (bounds["Height"] as? NSNumber)?.doubleValue else { continue }
                let pointX = Double(point.x)
                let pointY = Double(point.y)
                if pointX >= originX, pointX <= originX + winWidth,
                   pointY >= originY, pointY <= originY + winHeight {
                    if let pid = window["kCGWindowOwnerPID"] as? NSNumber,
                       let bundleId = NSRunningApplication(processIdentifier: pid.int32Value)?.bundleIdentifier {
                        return bundleId
                    }
                    break
                }
            }
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func verboseLog(_ message: String) {
        guard config.verbose else { return }
        let offset = String(format: "%6.3f", Date().timeIntervalSince(bootTime))
        log("[+\(offset)s] \(message)")
    }
}

// MARK: - Main

let config = parseConfig()

if let path = config.logFile {
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        logFileHandle = handle
    }
}

let triggerParts: [String] = {
    var parts: [String] = []
    if let modifier = config.modifier { parts.append("hold \(modifierName(modifier)) + scroll wheel") }
    if !config.buttons.isEmpty {
        parts.append("hold side button (\(config.buttons.sorted().map(String.init).joined(separator: " / "))) + scroll wheel")
    }
    return parts
}()

print("MouseZoomOnMac")
print("  trigger(s):  \(triggerParts.joined(separator: "\n               "))")
print("  scale:      wheel delta / \(config.scale) (MMF v3 default)")
print("  chromium:   burst hack \(config.chromiumBurst ? "ON" : "off")")
if !AXIsProcessTrusted() {
    // Ask the system to show the Accessibility permission prompt (works when run as an .app or LaunchAgent)
    let promptOptions: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    AXIsProcessTrustedWithOptions(promptOptions)
    print("  WARNING:    Accessibility is NOT granted to this binary yet.")
    print("            System Settings > Privacy & Security > Accessibility")
    print("            (also Input Monitoring) -> add MouseZoomOnMac, then restart.")
    print("            TIP: for a proper permission prompt, run:  open \"MouseZoomOnMac.app\"")
}

let engine = Engine(config)
var attempt = 0
while !engine.tryStart() {
    attempt += 1
    if attempt % 10 == 1 {
        let axTrusted = AXIsProcessTrusted()
        log("waiting: Accessibility granted=\(axTrusted) — if that is true, also enable MouseZoomOnMac in the INPUT MONITORING list (attempt \(attempt))")
    }
    if attempt % 15 == 1 {
        // Re-raise the system prompt (it offers an "Open System Settings" button that
        // registers the app in the TCC lists properly)
        let promptOptions: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(promptOptions)
    }
    Thread.sleep(forTimeInterval: 1.0)
}
log("event tap active")
log("Ready. Pinch-zoom by holding the trigger and scrolling. Release to end.")
print("Plain scroll (no trigger) passes through as normal scrolling/panning. Ctrl-C to quit.")

CFRunLoopRun()
