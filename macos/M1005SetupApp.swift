import AppKit
import Foundation
import ServiceManagement

private enum Product {
    static let servicePlist = "com.m1005printer.service.v9.plist"
    static let serviceLabel = "com.m1005printer.service.v9"
    static let legacyServicePlists = [
        "com.m1005printer.service.v7.plist",
        "com.m1005printer.service.v8.plist"
    ]
    static let legacyServiceLabels = [
        "com.m1005printer.service",
        "com.m1005printer.service.v2",
        "com.m1005printer.service.v3",
        "com.m1005printer.service.v4",
        "com.m1005printer.service.v5",
        "com.m1005printer.service.v6",
        "com.m1005printer.service.v7",
        "com.m1005printer.service.v8"
    ]
    static let queueName = "HP_LaserJet_M1005"
    static let printerName = "HP LaserJet M1005 MFP (USB)"
    static let printerURI =
        "ipp://localhost:8765/ipp/print/HP_LaserJet_M1005_MFP_(USB)"
    static let webURL = URL(string: "http://localhost:8765/")!
}

private struct CommandResult {
    let status: Int32
    let output: String
}

private struct IntegrationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct IntegrationStatus {
    let usb: String
    let service: String
    let server: String
    let queue: String

    var text: String {
        "usb=\(usb)\nservice=\(service)\nserver=\(server)\nqueue=\(queue)"
    }
}

private final class IntegrationManager {
    private var service: SMAppService {
        SMAppService.agent(plistName: Product.servicePlist)
    }

    private var helperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("m1005-printer-service")
    }

    private var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("M1005Printer", isDirectory: true)
    }

    private var stopMarkerURL: URL {
        appSupportURL.appendingPathComponent("service-stopped")
    }

    private var uninstallerURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("uninstall-m1005")
    }

    var logDirectoryURL: URL {
        FileManager.default.urls(for: .libraryDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("M1005Printer", isDirectory: true)
    }

    var logURL: URL {
        logDirectoryURL.appendingPathComponent("service.log")
    }

    private func run(_ executable: String, _ arguments: [String],
                     environment additions: [String: String] = [:]) -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "C"
        environment["LC_ALL"] = "C"
        for (key, value) in additions {
            environment[key] = value
        }
        process.environment = environment

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(
                status: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self).trimmingCharacters(
                    in: .whitespacesAndNewlines))
        } catch {
            return CommandResult(status: 127, output: error.localizedDescription)
        }
    }

    private func serviceStatusText() -> String {
        switch service.status {
        case .notRegistered:
            return "disabled"
        case .enabled:
            return FileManager.default.fileExists(atPath: stopMarkerURL.path)
                ? "stopped by user" : "enabled"
        case .requiresApproval:
            return "approval required"
        case .notFound:
            return "not found"
        @unknown default:
            return "unknown"
        }
    }

    private func usbStatusText() -> String {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return "helper missing"
        }
        let result = run(helperURL.path, ["--usb-status"])
        switch result.status {
        case 0:
            return "connected"
        case 2:
            return "connected (USB access busy)"
        default:
            return "disconnected"
        }
    }

    private func serverIsReady(fullIPPCheck: Bool = false) -> Bool {
        if fullIPPCheck {
            let test = "/usr/share/cups/ipptool/get-printer-attributes.test"
            guard FileManager.default.fileExists(atPath: test) else {
                return false
            }
            return run("/usr/bin/ipptool", ["-t", Product.printerURI, test]).status == 0
        }
        return run("/usr/bin/nc", ["-z", "127.0.0.1", "8765"]).status == 0
    }

    private func queueStatusText() -> String {
        let device = run("/usr/bin/lpstat", ["-v", Product.queueName])
        guard device.status == 0 else { return "not installed" }
        return device.output.contains("ipp://localhost:8765/ipp/print")
            ? "installed" : "needs update"
    }

    private func queueIsInstalled() -> Bool {
        run("/usr/bin/lpstat", ["-p", Product.queueName]).status == 0
    }

    private func setStoppedByUser(_ stopped: Bool) throws {
        try FileManager.default.createDirectory(at: appSupportURL,
                                                withIntermediateDirectories: true)
        if stopped {
            try Data("Stopped by the user. Start with the M1005 app.\n".utf8)
                .write(to: stopMarkerURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: stopMarkerURL.path) {
            try FileManager.default.removeItem(at: stopMarkerURL)
        }
    }

    private func cleanupLegacyServices() {
        let domain = "gui/\(getuid())"
        for plistName in Product.legacyServicePlists {
            let legacy = SMAppService.agent(plistName: plistName)
            if legacy.status != .notRegistered {
                try? legacy.unregister()
            }
        }
        for label in Product.legacyServiceLabels {
            _ = run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        }
    }

    private func removeCurrentRegistration() {
        if service.status != .notRegistered {
            try? service.unregister()
        }
        let target = "gui/\(getuid())/\(Product.serviceLabel)"
        _ = run("/bin/launchctl", ["bootout", target])
        for _ in 0..<20 {
            if run("/bin/launchctl", ["print", target]).status != 0 {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func waitForServer(running: Bool, attempts: Int = 30) -> Bool {
        for _ in 0..<attempts {
            if serverIsReady() == running {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return serverIsReady() == running
    }

    func status() -> IntegrationStatus {
        IntegrationStatus(
            usb: usbStatusText(),
            service: serviceStatusText(),
            server: serverIsReady() ? "running" : "stopped",
            queue: queueStatusText())
    }

    private func registerService() throws {
        try FileManager.default.createDirectory(at: appSupportURL,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectoryURL,
                                                withIntermediateDirectories: true)

        // An ad-hoc development update can leave ServiceManagement reporting
        // an enabled/not-found item whose launchd job exits with EX_CONFIG.
        // Port health is authoritative: replace any registration that cannot
        // actually provide the local IPP service.
        if !serverIsReady() {
            removeCurrentRegistration()
            do {
                try service.register()
            } catch {
                removeCurrentRegistration()
                Thread.sleep(forTimeInterval: 0.5)
                do {
                    try service.register()
                } catch {
                    throw IntegrationError(message:
                        "Unable to register the background printer service: \(error.localizedDescription)")
                }
            }
        } else if service.status == .notRegistered {
            try service.register()
        }
        if service.status == .requiresApproval {
            throw IntegrationError(message:
                "Background service approval is required in System Settings → General → Login Items.")
        }
    }

    func startService() throws -> String {
        try setStoppedByUser(false)
        cleanupLegacyServices()
        try registerService()

        let target = "gui/\(getuid())/\(Product.serviceLabel)"
        let kickstart = run("/bin/launchctl", ["kickstart", target])
        guard waitForServer(running: true) else {
            throw IntegrationError(message:
                "The printer service did not start on port 8765. \(kickstart.output)")
        }
        return "Background printer service started."
    }

    func enableService() throws {
        _ = try startService()
    }

    func stopService() throws -> String {
        try setStoppedByUser(true)
        guard serverIsReady() else {
            return "Background printer service is stopped. It will remain stopped until you start it from this app."
        }

        let shutdown = run(helperURL.path, ["shutdown"], environment: [
            "XDG_CONFIG_HOME": appSupportURL.path
        ])
        if shutdown.status != 0 && serverIsReady() {
            let target = "gui/\(getuid())/\(Product.serviceLabel)"
            _ = run("/bin/launchctl", ["kill", "SIGTERM", target])
        }
        guard waitForServer(running: false) else {
            throw IntegrationError(message:
                "The service did not stop cleanly: \(shutdown.output)")
        }
        return "Background printer service stopped. It will remain stopped until you start it from this app."
    }

    func addQueue() throws {
        var ready = false
        for _ in 0..<30 {
            if serverIsReady(fullIPPCheck: true) {
                ready = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        guard ready else {
            throw IntegrationError(message:
                "The local printer service did not become ready on port 8765.")
        }

        let serviceQuality = run(helperURL.path, [
            "modify",
            "-d", Product.printerName,
            "-o", "print-quality-default=high"
        ])
        guard serviceQuality.status == 0 else {
            throw IntegrationError(message:
                "Unable to enable maximum printer quality: \(serviceQuality.output)")
        }

        let result = run("/usr/sbin/lpadmin", [
            "-p", Product.queueName,
            "-E",
            "-v", Product.printerURI,
            "-m", "everywhere",
            "-o", "cupsPrintQuality-default=High"
        ])
        guard result.status == 0 else {
            throw IntegrationError(message:
                "Unable to add the macOS printer queue: \(result.output)")
        }
    }

    func enableAndAddQueue() throws -> String {
        _ = try startService()
        try addQueue()
        return "Background service enabled and HP_LaserJet_M1005 added to macOS."
    }

    func disableService() throws -> String {
        try setStoppedByUser(true)
        if service.status != .notRegistered {
            do {
                try service.unregister()
            } catch where service.status == .notFound {
                let target = "gui/\(getuid())/\(Product.serviceLabel)"
                _ = run("/bin/launchctl", ["bootout", target])
            }
        }
        _ = waitForServer(running: false)
        return "Background printer service disabled at login."
    }

    func removeQueue() throws -> String {
        if queueIsInstalled() {
            let result = run("/usr/sbin/lpadmin", ["-x", Product.queueName])
            guard result.status == 0 else {
                throw IntegrationError(message:
                    "Unable to remove the macOS printer queue: \(result.output)")
            }
        }
        return "HP_LaserJet_M1005 removed from macOS."
    }

    private func removeManagedData() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: appSupportURL.path) {
            try manager.removeItem(at: appSupportURL)
        }
        if manager.fileExists(atPath: logDirectoryURL.path) {
            try manager.removeItem(at: logDirectoryURL)
        }

        let supportParent = manager.urls(for: .applicationSupportDirectory,
                                         in: .userDomainMask)[0]
        for suffix in ["conf", "state", "d"] {
            let item = supportParent.appendingPathComponent(
                "m1005-printer-service.\(suffix)",
                isDirectory: suffix == "d")
            if manager.fileExists(atPath: item.path) {
                try manager.removeItem(at: item)
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func uninstallCompletely() throws -> String {
        _ = try removeQueue()
        _ = try disableService()
        cleanupLegacyServices()
        try removeManagedData()

        guard FileManager.default.isExecutableFile(atPath: uninstallerURL.path) else {
            throw IntegrationError(message: "The bundled complete uninstaller is missing.")
        }
        let command = [
            shellQuote(uninstallerURL.path),
            String(getuid()),
            shellQuote(FileManager.default.homeDirectoryForCurrentUser.path),
            shellQuote(Bundle.main.bundleURL.path)
        ].joined(separator: " ")
        let source = "do shell script \(appleScriptLiteral(command)) with administrator privileges"
        let result = run("/usr/bin/osascript", ["-e", source])
        guard result.status == 0 else {
            throw IntegrationError(message:
                result.output.isEmpty ? "Complete uninstall was cancelled." : result.output)
        }
        return result.output.isEmpty
            ? "M1005 was completely uninstalled." : result.output
    }

    func recentLog() -> String {
        guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else {
            return "No service log has been created yet."
        }
        return contents.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(40).joined(separator: "\n")
    }

    func validateBundle() throws -> String {
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(Product.servicePlist)
        let required = [helperURL, plist, uninstallerURL,
                        Bundle.main.bundleURL.appendingPathComponent(
                            "Contents/Resources/m1005-xqx-encode")]
        for item in required where !FileManager.default.fileExists(atPath: item.path) {
            throw IntegrationError(message: "Missing bundled component: \(item.path)")
        }
        guard Bundle.main.bundleIdentifier == "com.m1005printer.setup" else {
            throw IntegrationError(message: "Unexpected application bundle identifier.")
        }
        return "Bundle structure is valid."
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let integration = IntegrationManager()
    private var window: NSWindow!
    private let usbValue = NSTextField(labelWithString: "Checking…")
    private let serviceValue = NSTextField(labelWithString: "Checking…")
    private let serverValue = NSTextField(labelWithString: "Checking…")
    private let queueValue = NSTextField(labelWithString: "Checking…")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let logView = NSTextView()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        refresh(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) {
            [weak self] _ in self?.refresh(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 13, weight: .medium)
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 610),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "HP LaserJet M1005 Setup"
        window.center()

        let title = NSTextField(labelWithString: "HP LaserJet M1005")
        title.font = .systemFont(ofSize: 25, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString:
            "Modern local Printer Application for macOS 26. Connect the printer by USB, start the background service, then add the driverless queue.")
        subtitle.textColor = .secondaryLabelColor

        let statusGrid = NSGridView(views: [
            [label("USB printer"), usbValue],
            [label("Background service"), serviceValue],
            [label("Local IPP server"), serverValue],
            [label("macOS print queue"), queueValue]
        ])
        statusGrid.column(at: 0).xPlacement = .trailing
        statusGrid.column(at: 1).xPlacement = .leading
        statusGrid.rowSpacing = 7
        statusGrid.columnSpacing = 18

        let primaryButtons = NSStackView(views: [
            button("Start Service & Add Printer", action: #selector(enableAndAdd(_:))),
            button("Refresh", action: #selector(refresh(_:))),
            button("Open Printer Page", action: #selector(openPrinterPage(_:)))
        ])
        primaryButtons.orientation = .horizontal
        primaryButtons.spacing = 10

        let maintenanceButtons = NSStackView(views: [
            button("Start Service", action: #selector(startService(_:))),
            button("Stop Service", action: #selector(stopService(_:))),
            button("Disable at Login", action: #selector(disableService(_:))),
            button("Remove Printer", action: #selector(removeQueue(_:))),
        ])
        maintenanceButtons.orientation = .horizontal
        maintenanceButtons.spacing = 8

        let removalButtons = NSStackView(views: [
            button("Login Items Settings", action: #selector(openLoginItems(_:))),
            button("Uninstall M1005 Completely…", action: #selector(uninstall(_:)))
        ])
        removalButtons.orientation = .horizontal
        removalButtons.spacing = 8

        let logLabel = label("Recent service log")
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = .textBackgroundColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = logView
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        message.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, subtitle, statusGrid,
                                        primaryButtons, maintenanceButtons,
                                        removalButtons, message, logLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor,
                                           constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor,
                                            constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor,
                                       constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo:
                window.contentView!.bottomAnchor, constant: -20),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func apply(_ status: IntegrationStatus) {
        usbValue.stringValue = status.usb
        serviceValue.stringValue = status.service
        serverValue.stringValue = status.server
        queueValue.stringValue = status.queue
        logView.string = integration.recentLog()
    }

    private func perform(_ progress: String,
                         action: @escaping () throws -> String) {
        message.stringValue = progress
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try action()
                let status = self?.integration.status()
                DispatchQueue.main.async {
                    self?.message.stringValue = result
                    if let status { self?.apply(status) }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.message.stringValue = error.localizedDescription
                    self?.refresh(nil)
                }
            }
        }
    }

    @objc private func refresh(_ sender: Any?) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let status = integration.status()
            let log = integration.recentLog()
            DispatchQueue.main.async {
                self.apply(status)
                self.logView.string = log
            }
        }
    }

    @objc private func enableAndAdd(_ sender: Any?) {
        perform("Starting the service and waiting for the IPP printer…") {
            try self.integration.enableAndAddQueue()
        }
    }

    @objc private func startService(_ sender: Any?) {
        perform("Starting the background printer service…") {
            try self.integration.startService()
        }
    }

    @objc private func stopService(_ sender: Any?) {
        perform("Stopping the background printer service…") {
            try self.integration.stopService()
        }
    }

    @objc private func disableService(_ sender: Any?) {
        perform("Disabling the background service at login…") {
            try self.integration.disableService()
        }
    }

    @objc private func removeQueue(_ sender: Any?) {
        perform("Removing the macOS printer queue…") {
            try self.integration.removeQueue()
        }
    }

    @objc private func openPrinterPage(_ sender: Any?) {
        NSWorkspace.shared.open(Product.webURL)
    }

    @objc private func openLoginItems(_ sender: Any?) {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func uninstall(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Completely uninstall M1005?"
        alert.informativeText = "This removes every installed M1005 app, the print queue, current and legacy background services, pending spool files, settings, logs, and the installer receipt. An administrator password may be required."
        alert.addButton(withTitle: "Uninstall Completely")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        message.stringValue = "Completely removing M1005…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                _ = try integration.uninstallCompletely()
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.message.stringValue = error.localizedDescription
                    self.refresh(nil)
                }
            }
        }
    }
}

@main
private enum M1005SetupMain {
    static func main() {
        let integration = IntegrationManager()
        if CommandLine.arguments.count > 1 {
            let command = CommandLine.arguments[1]
            do {
                let output: String
                switch command {
                case "--status":
                    output = integration.status().text
                case "--enable":
                    output = try integration.enableAndAddQueue()
                case "--enable-service":
                    try integration.enableService()
                    output = "Background printer service enabled."
                case "--start-service":
                    output = try integration.startService()
                case "--stop-service":
                    output = try integration.stopService()
                case "--add-queue":
                    try integration.addQueue()
                    output = "HP_LaserJet_M1005 added to macOS."
                case "--disable":
                    output = try integration.disableService()
                case "--remove-queue":
                    output = try integration.removeQueue()
                case "--uninstall":
                    output = try integration.uninstallCompletely()
                case "--validate-bundle":
                    output = try integration.validateBundle()
                default:
                    throw IntegrationError(message:
                        "Usage: M1005 Setup [--status|--enable|--enable-service|--start-service|--stop-service|--add-queue|--disable|--remove-queue|--uninstall|--validate-bundle]")
                }
                print(output)
                Foundation.exit(EXIT_SUCCESS)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                Foundation.exit(EXIT_FAILURE)
            }
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
