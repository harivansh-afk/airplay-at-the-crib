import AppKit
import Foundation

// System tools are passed separate arguments, never interpreted by a shell.
func run(_ path: String, _ args: [String]) -> String {
    let task = Process(), output = Pipe()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return "" }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return task.terminationStatus == 0 ? String(data: data, encoding: .utf8) ?? "" : ""
}

func ipv4(_ s: String) -> Bool {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && (Int($0).map { 0...255 ~= $0 } ?? false) }
}

func privateIP(_ s: String) -> Bool {
    guard ipv4(s) else { return false }
    let p = s.split(separator: ".").compactMap { Int($0) }
    return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
}

struct TV {
    let ip: String, name: String, id: String
}

final class XMLFields: NSObject, XMLParserDelegate {
    var fields: [String: String] = [:], key = "", content = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { key = elementName; content = "" }
    func parser(_ parser: XMLParser, foundCharacters string: String) { content += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { fields[elementName] = content }
}

func probe(_ ip: String) -> TV? {
    guard privateIP(ip) else { return nil }
    let xml = run("/usr/bin/curl", ["--noproxy", "*", "--silent", "--fail", "--connect-timeout", "1", "--max-time", "2", "--max-filesize", "65536", "http://\(ip):8060/query/device-info"])
    guard let data = xml.data(using: .utf8) else { return nil }
    let fields = XMLFields(), parser = XMLParser(data: data)
    parser.delegate = fields
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), fields.fields["supports-airplay"] == "true", let id = fields.fields["udn"], !id.isEmpty else { return nil }
    return TV(ip: ip, name: fields.fields["friendly-device-name"] ?? "Roku TV", id: id)
}

// Decode DNS presentation escapes (including decimal octets), not shell escapes.
func dnsUnescape(_ s: String) -> String {
    let bytes = Array(s.utf8)
    var out: [UInt8] = [], i = 0
    while i < bytes.count {
        if bytes[i] == 92 && i + 1 < bytes.count {
            if i + 3 < bytes.count, bytes[(i+1)...(i+3)].allSatisfy({ 48...57 ~= $0 }),
               let n = Int(String(bytes: bytes[(i+1)...(i+3)], encoding: .utf8)!), n <= 255 {
                out.append(UInt8(n)); i += 4; continue
            }
            i += 1
        }
        out.append(bytes[i]); i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

struct Announcement: Equatable {
    let name: String, host: String, port: String, txt: [String]
    static func parse(_ output: String) -> Announcement? {
        var name = "", host = "", port = "", txt: [String] = []
        let pattern = try! NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)""#)
        for line in output.split(separator: "\n") where !line.hasPrefix(";") {
            let f = line.split(maxSplits: 4, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard f.count == 5 else { continue }
            if f[3] == "PTR", f[4].hasSuffix("._airplay._tcp.local.") {
                name = dnsUnescape(String(f[4].dropLast("._airplay._tcp.local.".count)))
            }
            if f[3] == "SRV" {
                let srv = f[4].split(whereSeparator: \.isWhitespace)
                if srv.count == 4 { port = String(srv[2]); host = String(srv[3]) }
            }
            if f[3] == "TXT" {
                let s = f[4] as NSString
                txt = pattern.matches(in: f[4], range: NSRange(location: 0, length: s.length)).map { dnsUnescape(s.substring(with: $0.range(at: 1))) }
            }
        }
        guard !name.isEmpty, !host.isEmpty, let p = Int(port), (1...65535).contains(p), !txt.isEmpty else { return nil }
        return Announcement(name: name, host: host, port: port, txt: txt)
    }
}

func announcement(_ ip: String) -> Announcement? {
    guard privateIP(ip) else { return nil }
    return Announcement.parse(run("/usr/bin/dig", ["@\(ip)", "-p", "5353", "_airplay._tcp.local", "PTR", "+time=2", "+tries=2", "+noall", "+answer", "+additional"]))
}

// Only probe a bounded set of local /24 ranges observed on the active LAN.
// This deliberately does not sweep every address in a building's /16.
func candidates() -> [String] {
    let route = run("/sbin/route", ["-n", "get", "default"])
    func field(_ key: String) -> String? { route.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) }
    guard let iface = field("interface"), let gateway = field("gateway"), privateIP(gateway) else { return [] }
    let local = run("/usr/sbin/ipconfig", ["getifaddr", iface]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard privateIP(local) else { return [] }
    let mask = run("/usr/sbin/ipconfig", ["getoption", iface, "subnet_mask"]).trimmingCharacters(in: .whitespacesAndNewlines)
    func number(_ ip: String) -> UInt32 { ip.split(separator: ".").reduce(UInt32(0)) { ($0 << 8) | (UInt32($1) ?? 0) } }
    let netmask = ipv4(mask) ? number(mask) : 0xffffff00
    func sameSubnet(_ ip: String) -> Bool { privateIP(ip) && number(ip) & netmask == number(local) & netmask }
    var ranges: [String] = []
    func add(_ ip: String) { let prefix = ip.split(separator: ".").dropLast().joined(separator: "."); if sameSubnet(ip) && !ranges.contains(prefix) && ranges.count < 4 { ranges.append(prefix) } }
    add(local); add(gateway)
    let arp = run("/usr/sbin/arp", ["-an", "-i", iface])
    let regex = try! NSRegularExpression(pattern: #"\(([0-9.]+)\)"#)
    let s = arp as NSString
    let neighbors = regex.matches(in: arp, range: NSRange(location: 0, length: s.length)).map { s.substring(with: $0.range(at: 1)) }.filter(sameSubnet)
    neighbors.forEach(add)
    var seen = Set<String>()
    return (neighbors + ranges.flatMap { prefix in (1...254).map { "\(prefix).\($0)" } }).filter { $0 != local && sameSubnet($0) && seen.insert($0).inserted }
}

final class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow!, statusItem: NSStatusItem!, table = NSTableView()
    let status = NSTextField(wrappingLabelWithString: "Join the same Wi-Fi as your TV, then find it below.")
    let scanButton = NSButton(title: "Find TVs", target: nil, action: nil)
    let connectButton = NSButton(title: "Show in AirPlay", target: nil, action: nil)
    let spinner = NSProgressIndicator()
    var tvs: [TV] = [], selected: TV?, proxy: Process?, current: Announcement?
    var timer: Timer?, busy = false, refreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), appMenu = NSMenu(), root = NSMenuItem()
        root.submenu = appMenu; menu.addItem(root)
        appMenu.addItem(withTitle: "Quit AirplayAtTheCrib", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "airplayvideo", accessibilityDescription: "AirplayAtTheCrib")
        let tray = NSMenu()
        let show = tray.addItem(withTitle: "Open AirplayAtTheCrib", action: #selector(showWindow), keyEquivalent: ""); show.target = self
        let stop = tray.addItem(withTitle: "Stop sharing TV discovery", action: #selector(stopProxy), keyEquivalent: ""); stop.target = self
        tray.addItem(.separator())
        tray.addItem(withTitle: "Quit AirplayAtTheCrib", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = tray
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 490), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "AirplayAtTheCrib"; window.center(); window.isReleasedWhenClosed = false
        let content = window.contentView!
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28)])
        let title = NSTextField(labelWithString: "Your TV. On your Mac."); title.font = .systemFont(ofSize: 26, weight: .bold)
        stack.addArrangedSubview(title)
        let intro = NSTextField(wrappingLabelWithString: "Find your Roku, make it visible, then choose it in Screen Mirroring."); intro.textColor = .secondaryLabelColor
        stack.addArrangedSubview(intro)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TV")); col.title = "Available TVs"; col.width = 500; table.addTableColumn(col)
        table.headerView = nil; table.rowHeight = 54; table.dataSource = self; table.delegate = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll); scroll.heightAnchor.constraint(equalToConstant: 185).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scanButton.target = self; scanButton.action = #selector(scan)
        connectButton.target = self; connectButton.action = #selector(connect); connectButton.bezelStyle = .rounded; connectButton.isEnabled = false
        let manual = NSButton(title: "Enter TV address…", target: self, action: #selector(manualIP))
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let buttons = NSStackView(views: [scanButton, manual, connectButton, spinner]); buttons.spacing = 10
        stack.addArrangedSubview(buttons)
        status.font = .systemFont(ofSize: 13); status.widthAnchor.constraint(equalToConstant: 524).isActive = true; stack.addArrangedSubview(status)
        let note = NSTextField(wrappingLabelWithString: "Keep AirplayAtTheCrib open while casting. Closing this window leaves it in the menu bar. Quit from its menu when you’re done."); note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        showWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); proxy?.terminate() }
    func numberOfRows(in tableView: NSTableView) -> Int { tvs.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tv = tvs[row]
        let cell = NSTextField(wrappingLabelWithString: "\(tv.name)\n\(tv.ip)"); cell.font = .systemFont(ofSize: 14); return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { connectButton.isEnabled = table.selectedRow >= 0 && !busy }
    func setBusy(_ value: Bool) { busy = value; scanButton.isEnabled = !value; connectButton.isEnabled = !value && table.selectedRow >= 0; if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) } }

    @objc func scan() {
        guard !busy else { return }; setBusy(true); tvs = []; table.reloadData()
        status.stringValue = "Looking for TVs on your Wi-Fi… Allow Local Network access if your Mac asks."
        DispatchQueue.global().async {
            let ips = candidates(), queue = OperationQueue(); queue.maxConcurrentOperationCount = 24
            for ip in ips { queue.addOperation { if let tv = probe(ip) { DispatchQueue.main.async {
                if !self.tvs.contains(where: { $0.id == tv.id }) { self.tvs.append(tv); self.tvs.sort { $0.name < $1.name }; self.table.reloadData() }
            } } } }
            queue.waitUntilAllOperationsAreFinished()
            DispatchQueue.main.async { self.setBusy(false); self.status.stringValue = self.tvs.isEmpty ? "No TVs found. Check Local Network permission and your Wi-Fi, or choose Enter TV address. On your Roku, find it under Settings → Network → About." : "Choose your TV, then click Show in AirPlay. Other people’s TVs may appear on shared Wi-Fi." }
        }
    }

    @objc func manualIP() {
        guard !busy else { return }
        let alert = NSAlert(); alert.messageText = "Enter your Roku’s IP address"; alert.informativeText = "On your TV: Settings → Network → About. Look for IP address."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 24)); field.placeholderString = "For example, 192.168.1.25"; alert.accessoryView = field
        alert.addButton(withTitle: "Find TV"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let ip = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard privateIP(ip) else { self.status.stringValue = "Enter a local IP address using four numbers separated by dots."; return }
            self.setBusy(true); self.status.stringValue = "Checking your TV…"
            DispatchQueue.global().async {
                let tv = probe(ip)
                DispatchQueue.main.async { self.setBusy(false); if let tv {
                    self.tvs.removeAll { $0.id == tv.id }; self.tvs.append(tv); self.table.reloadData(); self.table.selectRowIndexes(IndexSet(integer: self.tvs.count - 1), byExtendingSelection: false); self.status.stringValue = "Found \(tv.name). Click Show in AirPlay."
                } else { self.status.stringValue = "Couldn’t reach an AirPlay-capable Roku there. Check the address, Wi-Fi, and Local Network permission." } }
            }
        }
    }

    @objc func connect() {
        let row = table.selectedRow; guard !busy, tvs.indices.contains(row) else { return }
        let tv = tvs[row]; setBusy(true); status.stringValue = "Reading your TV’s AirPlay settings…"
        DispatchQueue.global().async {
            let verified = probe(tv.ip), record = announcement(tv.ip)
            DispatchQueue.main.async {
                self.setBusy(false)
                guard verified?.id == tv.id, let record else { self.status.stringValue = "Couldn’t read AirPlay settings. On the TV, open Settings → Apple AirPlay and HomeKit and turn AirPlay on, then try again."; return }
                self.publish(tv, record)
            }
        }
    }

    func publish(_ tv: TV, _ record: Announcement) {
        proxy?.terminationHandler = nil; proxy?.terminate()
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        task.arguments = ["-lo", "-P", record.name, "_airplay._tcp", "local.", record.port, record.host, tv.ip] + record.txt
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] p in DispatchQueue.main.async { guard let self, self.proxy === p else { return }; self.proxy = nil; self.current = nil; self.status.stringValue = "Discovery stopped. Click Show in AirPlay to try again." } }
        do {
            try task.run(); proxy = task; selected = tv; current = record
            status.stringValue = "Ready: \(tv.name)\nOpen Control Center → Screen Mirroring and choose this TV. Enter the code shown on the TV if asked."
        } catch { proxy = nil; selected = nil; current = nil; status.stringValue = "Couldn’t start discovery. Quit and reopen AirplayAtTheCrib, then try again." }
    }

    @objc func stopProxy() { proxy?.terminationHandler = nil; proxy?.terminate(); proxy = nil; selected = nil; current = nil; status.stringValue = "Stopped. Select a TV to make it available again." }
    func refresh() {
        guard !busy, !refreshing, let tv = selected else { return }; refreshing = true
        DispatchQueue.global().async {
            let verified = probe(tv.ip), record = announcement(tv.ip)
            DispatchQueue.main.async {
                self.refreshing = false
                guard self.selected?.id == tv.id, self.selected?.ip == tv.ip else { return }
                guard verified?.id == tv.id, let record else { self.stopProxy(); self.status.stringValue = "Your TV is no longer reachable. Wake it or rejoin its Wi-Fi, then click Find TVs."; return }
                if record != self.current || self.proxy?.isRunning != true { self.publish(tv, record) }
            }
        }
    }
}

if CommandLine.arguments.contains("--self-test") {
    precondition(privateIP("10.41.1.210") && !privateIP("8.8.8.8") && !ipv4("1.2.3.999"))
    precondition(dnsUnescape(#"Living\032Room"#) == "Living Room")
    let sample = #"""
_airplay._tcp.local. 10 IN PTR Living\032Room._airplay._tcp.local.
Living\032Room._airplay._tcp.local. 10 IN SRV 0 0 7000 tv.local.
Living\032Room._airplay._tcp.local. 10 IN TXT "model=Roku" "name=Room\032TV" "pk=abc"
"""#
    let r = Announcement.parse(sample)!
    precondition(r.name == "Living Room" && r.port == "7000" && r.txt == ["model=Roku", "name=Room TV", "pk=abc"])
    precondition(Announcement.parse("garbage") == nil)
    print("Parsing and address checks passed.")
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--probe" {
    let ip = CommandLine.arguments[2]
    guard let tv = probe(ip), let record = announcement(ip) else { fputs("TV or AirPlay announcement unavailable.\n", stderr); exit(1) }
    print("\(tv.name) at \(tv.ip): AirPlay \(record.name), port \(record.port), \(record.txt.count) TXT fields")
} else {
    let app = NSApplication.shared, delegate = App(); app.delegate = delegate; app.run()
}
