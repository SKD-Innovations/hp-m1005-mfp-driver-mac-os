import AppKit
import Foundation
import ServiceManagement

private enum Product {
    static let servicePlist = "com.m1005printer.service.v5.plist"
    static let queueName = "HP_LaserJet_M1005"
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

    var logDirectoryURL: URL {
        FileManager.default.urls(for: .libraryDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("M1005Printer", isDirectory: true)
    }

    var logURL: URL {
        logDirectoryURL.appendingPathComponent("service.log")
    }

    private func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "C"
        environment["LC_ALL"] = "C"
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
            return "enabled"
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
        return run(helperURL.path, ["--usb-status"]).status == 0
            ? "connected" : "disconnected"
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

    func status() -> IntegrationStatus {
        IntegrationStatus(
            usb: usbStatusText(),
            service: serviceStatusText(),
            server: serverIsReady() ? "running" : "stopped",
            queue: queueStatusText())
    }

    func enableService() throws {
        try FileManager.default.createDirectory(at: appSupportURL,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectoryURL,
                                                withIntermediateDirectories: true)
        if service.status == .notRegistered || service.status == .notFound {
            try service.register()
        }
        if service.status == .requiresApproval {
            throw IntegrationError(message:
                "Background service approval is required in System Settings → General → Login Items.")
        }
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

        let result = run("/usr/sbin/lpadmin", [
            "-p", Product.queueName,
            "-E",
            "-v", Product.printerURI,
            "-m", "everywhere"
        ])
        guard result.status == 0 else {
            throw IntegrationError(message:
                "Unable to add the macOS printer queue: \(result.output)")
        }
    }

    func enableAndAddQueue() throws -> String {
        try enableService()
        try addQueue()
        return "Background service enabled and HP_LaserJet_M1005 added to macOS."
    }

    func disableService() throws -> String {
        if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
        return "Background printer service disabled."
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

    func uninstallIntegration() throws -> String {
        _ = try removeQueue()
        _ = try disableService()

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
        return "Printer queue, background service, spool data, and logs removed. You may now move the app to Trash."
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
        let required = [helperURL, plist,
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
            "Modern local Printer Application for macOS 26. Connect the printer by USB, enable the background service, then add the driverless queue.")
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
            button("Enable Service & Add Printer", action: #selector(enableAndAdd(_:))),
            button("Refresh", action: #selector(refresh(_:))),
            button("Open Printer Page", action: #selector(openPrinterPage(_:)))
        ])
        primaryButtons.orientation = .horizontal
        primaryButtons.spacing = 10

        let maintenanceButtons = NSStackView(views: [
            button("Disable Service", action: #selector(disableService(_:))),
            button("Remove Printer", action: #selector(removeQueue(_:))),
            button("Login Items Settings", action: #selector(openLoginItems(_:))),
            button("Uninstall Integration…", action: #selector(uninstall(_:)))
        ])
        maintenanceButtons.orientation = .horizontal
        maintenanceButtons.spacing = 8

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
                                        message, logLabel, scroll])
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
        perform("Enabling the service and waiting for the IPP printer…") {
            try self.integration.enableAndAddQueue()
        }
    }

    @objc private func disableService(_ sender: Any?) {
        perform("Disabling the background service…") {
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
        alert.messageText = "Uninstall M1005 integration?"
        alert.informativeText = "This removes the print queue, background service, pending spool files, and service logs. The app itself can then be moved to Trash."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("Removing the local integration…") {
            try self.integration.uninstallIntegration()
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
                case "--add-queue":
                    try integration.addQueue()
                    output = "HP_LaserJet_M1005 added to macOS."
                case "--disable":
                    output = try integration.disableService()
                case "--remove-queue":
                    output = try integration.removeQueue()
                case "--uninstall":
                    output = try integration.uninstallIntegration()
                case "--validate-bundle":
                    output = try integration.validateBundle()
                default:
                    throw IntegrationError(message:
                        "Usage: M1005 Setup [--status|--enable|--enable-service|--add-queue|--disable|--remove-queue|--uninstall|--validate-bundle]")
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
