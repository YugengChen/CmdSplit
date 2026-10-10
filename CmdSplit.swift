import AppKit
import ApplicationServices
import Carbon

private let bundleID = "local.ychen.CmdSplit"
private let hotkeySignature: OSType = 0x434D5350

enum WindowAction: UInt32, CaseIterable {
    case left = 1, right = 2, maximize = 3
    var name: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        case .maximize: return "maximize"
        }
    }
    var keyCode: UInt32 {
        switch self {
        case .left: return UInt32(kVK_LeftArrow)
        case .right: return UInt32(kVK_RightArrow)
        case .maximize: return UInt32(kVK_UpArrow)
        }
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func focusedApplicationElement(workspacePID: pid_t) -> AXUIElement? {
    // NSRunningApplication may report -1 for a foreground app such as Preview.
    // Ask AX for the focused application before falling back to a valid workspace PID.
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 1)
    if let value = attribute(system, kAXFocusedApplicationAttribute),
       CFGetTypeID(value) == AXUIElementGetTypeID() {
        let application = value as! AXUIElement
        var pid: pid_t = 0
        if AXUIElementGetPid(application, &pid) == .success, pid > 0 {
            return application
        }
    }
    guard workspacePID > 0 else { return nil }
    return AXUIElementCreateApplication(workspacePID)
}

func windowRect(_ window: AXUIElement) -> CGRect? {
    guard let position = attribute(window, kAXPositionAttribute),
          let size = attribute(window, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(),
          CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}

func setPosition(_ point: CGPoint, on window: AXUIElement) -> AXError {
    var value = point
    guard let wrapped = AXValueCreate(.cgPoint, &value) else { return .failure }
    return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, wrapped)
}

func setSize(_ size: CGSize, on window: AXUIElement) -> AXError {
    var value = size
    guard let wrapped = AXValueCreate(.cgSize, &value) else { return .failure }
    return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, wrapped)
}

func rectDictionary(_ rect: CGRect) -> [String: Double] {
    ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var eventHandler: EventHandlerRef?
    private var hotkeys: [EventHotKeyRef] = []
    private var permissionTimer: Timer?
    private var trusted = false
    private var paused = UserDefaults.standard.bool(forKey: "paused")
    private var hotkeyError: OSStatus?
    private var lastSnap: [String: Any]?
    private var lastError: String?
    private var actionGeneration = 0
    private let stateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CmdSplit/status.json")
    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "左右分屏")
        statusItem.button?.image?.isTemplate = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
                nil, &identifier)
            guard result == noErr, identifier.signature == hotkeySignature,
                  let action = WindowAction(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.snap(action)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if handlerStatus != noErr { hotkeyError = handlerStatus }

        refreshPermission(force: true)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshPermission()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp),
            name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        if !trusted && !UserDefaults.standard.bool(forKey: "requestedAccessibility") {
            UserDefaults.standard.set(true, forKey: "requestedAccessibility")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.requestPermission()
            }
        }
    }

    private func refreshPermission(force: Bool = false) {
        let current = AXIsProcessTrusted()
        guard force || current != trusted else { return }
        trusted = current
        unregisterHotkeys()
        if trusted && !paused { registerHotkeys() }
        rebuildMenu()
        writeStatus()
    }

    private func registerHotkeys() {
        guard eventHandler != nil else { return }
        hotkeyError = nil
        for action in WindowAction.allCases {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(action.keyCode, UInt32(cmdKey),
                EventHotKeyID(signature: hotkeySignature, id: action.rawValue),
                GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else {
                hotkeyError = result
                unregisterHotkeys()
                return
            }
            hotkeys.append(reference)
        }
    }

    private func unregisterHotkeys() {
        for key in hotkeys { UnregisterEventHotKey(key) }
        hotkeys.removeAll()
    }

    @objc private func wokeUp() {
        refreshPermission(force: true)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let state = !trusted ? "请开启辅助功能权限" : paused ? "快捷键已暂停" :
            hotkeys.count == WindowAction.allCases.count ? "分屏与最大化已开启" : "快捷键冲突，请检查其他分屏工具"
        statusItem.button?.toolTip = "\(state) · ⌘← 左半屏 · ⌘→ 右半屏 · ⌘↑ 最大化"
        let heading = NSMenuItem(title: state, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let startup = NSMenuItem(title: FileManager.default.fileExists(atPath: agentURL.path)
            ? "登录后自动启动 · 退出后自动恢复" : "自动启动尚未安装", action: nil, keyEquivalent: "")
        startup.isEnabled = false
        menu.addItem(startup)
        menu.addItem(.separator())
        let left = NSMenuItem(title: "窗口移到左半屏    ⌘←", action: #selector(leftHalf), keyEquivalent: "")
        left.target = self
        left.isEnabled = trusted
        menu.addItem(left)
        let right = NSMenuItem(title: "窗口移到右半屏    ⌘→", action: #selector(rightHalf), keyEquivalent: "")
        right.target = self
        right.isEnabled = trusted
        menu.addItem(right)
        let maximize = NSMenuItem(title: "窗口最大化    ⌘↑", action: #selector(maximizeWindow), keyEquivalent: "")
        maximize.target = self
        maximize.isEnabled = trusted
        menu.addItem(maximize)
        menu.addItem(.separator())
        let pause = NSMenuItem(title: paused ? "恢复快捷键" : "暂停快捷键", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let permission = NSMenuItem(title: "辅助功能权限…", action: #selector(requestPermission), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "关闭并停用自动启动", action: #selector(disableAndQuit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func togglePause() {
        paused.toggle()
        UserDefaults.standard.set(paused, forKey: "paused")
        refreshPermission(force: true)
    }

    @objc private func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func leftHalf() { snap(.left) }
    @objc private func rightHalf() { snap(.right) }
    @objc private func maximizeWindow() { snap(.maximize) }

    @objc private func disableAndQuit() {
        unregisterHotkeys()
        do { try FileManager.default.removeItem(at: agentURL) }
        catch { if FileManager.default.fileExists(atPath: agentURL.path) { fail("不能移除自动启动设置"); return } }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(bundleID)"]
        if (try? process.run()) != nil { process.waitUntilExit() }
        NSApp.terminate(nil)
    }

    private func fail(_ message: String) {
        lastError = message
        writeStatus()
        NSLog("CmdSplit: %@", message)
        NSSound.beep()
    }

    private func snap(_ action: WindowAction) {
        actionGeneration += 1
        let generation = actionGeneration
        guard AXIsProcessTrusted() else { refreshPermission(force: true); return }
        guard let app = NSWorkspace.shared.frontmostApplication else { fail("没有前台应用"); return }
        guard let element = focusedApplicationElement(workspacePID: app.processIdentifier) else {
            fail("无法识别前台应用的窗口"); return
        }
        AXUIElementSetMessagingTimeout(element, 1)
        guard let value = attribute(element, kAXFocusedWindowAttribute) ?? attribute(element, kAXMainWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { fail("前台应用没有可调整的窗口"); return }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 1)
        if (attribute(window, "AXFullScreen") as? Bool) == true {
            let result = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            guard result == .success else { fail("此窗口不能退出全屏（\(result.rawValue)）"); return }
            waitForFullScreenExit(window, app: app, action: action, generation: generation, attempts: 24)
        } else {
            place(window, app: app, action: action, generation: generation)
        }
    }

    private func waitForFullScreenExit(_ window: AXUIElement, app: NSRunningApplication, action: WindowAction, generation: Int, attempts: Int) {
        guard attempts > 0 else { fail("退出全屏超时"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.actionGeneration == generation else { return }
            if (attribute(window, "AXFullScreen") as? Bool) == true {
                self.waitForFullScreenExit(window, app: app, action: action, generation: generation, attempts: attempts - 1)
            } else {
                // The full-screen transition may continue briefly after AXFullScreen becomes false.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard self.actionGeneration == generation else { return }
                    self.place(window, app: app, action: action, generation: generation)
                }
            }
        }
    }

    private func place(_ window: AXUIElement, app: NSRunningApplication, action: WindowAction, generation: Int) {
        guard let original = windowRect(window), let first = NSScreen.screens.first else {
            fail("无法读取窗口或屏幕尺寸"); return
        }
        var canResize = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &canResize) == .success,
              canResize.boolValue else { fail("此窗口不支持调整大小"); return }

        // AX uses a top-left origin; AppKit uses the primary display's bottom-left origin.
        let primaryTop = first.frame.maxY
        func axRect(_ frame: CGRect) -> CGRect {
            CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
        }
        let screen = NSScreen.screens.max { a, b in
            let aa = original.intersection(axRect(a.frame))
            let bb = original.intersection(axRect(b.frame))
            let areaA = aa.isNull ? 0 : aa.width * aa.height
            let areaB = bb.isNull ? 0 : bb.width * bb.height
            return areaA < areaB
        } ?? first
        let visible = axRect(screen.visibleFrame)
        let leftWidth = floor(visible.width / 2)
        let target: CGRect
        switch action {
        case .left:
            target = CGRect(x: visible.minX, y: visible.minY, width: leftWidth, height: visible.height)
        case .right:
            target = CGRect(x: visible.minX + leftWidth, y: visible.minY,
                width: visible.width - leftWidth, height: visible.height)
        case .maximize:
            target = visible
        }

        // Resize before moving, then retry size after the move for apps that constrain off-screen frames.
        _ = setSize(target.size, on: window)
        let positionResult = setPosition(target.origin, on: window)
        let sizeResult = setSize(target.size, on: window)
        guard positionResult == .success, sizeResult == .success else {
            fail("调整窗口失败（位置 \(positionResult.rawValue)，大小 \(sizeResult.rawValue)）"); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.actionGeneration == generation, let current = windowRect(window) else { return }
            // Keep the requested edge aligned if the application imposes a minimum width.
            let aligned = CGPoint(x: action == .right ? visible.maxX - current.width : visible.minX, y: visible.minY)
            _ = setPosition(aligned, on: window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard self.actionGeneration == generation else { return }
                guard let actual = windowRect(window) else { self.fail("无法验证窗口位置"); return }
                let exact = abs(actual.minX - target.minX) <= 2 && abs(actual.minY - target.minY) <= 2 &&
                    abs(actual.width - target.width) <= 2 && abs(actual.height - target.height) <= 2
                self.lastError = nil
                self.lastSnap = ["side": action.name, "app": app.bundleIdentifier ?? "unknown",
                    "time": ISO8601DateFormatter().string(from: Date()),
                    "target": rectDictionary(target), "actual": rectDictionary(actual),
                    "exactPlacement": exact,
                    "isFullScreen": (attribute(window, "AXFullScreen") as? Bool) ?? false]
                if action != .maximize { self.lastSnap?["exactHalf"] = exact }
                self.writeStatus()
            }
        }
    }

    private func writeStatus() {
        var value: [String: Any] = ["pid": getpid(), "version": "1.1.1", "axTrusted": trusted,
            "hotkeysRegistered": hotkeys.count == WindowAction.allCases.count,
            "hotkeyCount": hotkeys.count, "paused": paused,
            "autoStartInstalled": FileManager.default.fileExists(atPath: agentURL.path),
            "updatedAt": ISO8601DateFormatter().string(from: Date())]
        if let hotkeyError { value["hotkeyError"] = hotkeyError }
        if let lastSnap { value["lastSnap"] = lastSnap }
        if let lastError { value["lastError"] = lastError }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch { NSLog("CmdSplit status: %@", error.localizedDescription) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterHotkeys()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
