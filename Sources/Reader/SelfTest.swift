import AppKit
import ReaderCore

/// Acceptance checks against the real app, views and database, enabled only by environment:
///   READER_SELFTEST=<step> READER_SELFTEST_LOG=<file>
/// Each step opens the first library book, waits for the restore, acts like a user would
/// (scroll, resize, zoom, switch mode) and appends what it measured to the log as JSON lines.
/// Quitting and killing between steps is done from outside, so lifecycle is real too.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let step = env["READER_SELFTEST"], let logPath = env["READER_SELFTEST_LOG"] else { return }
        Task { @MainActor in
            await run(step: step, log: URL(fileURLWithPath: logPath), docIndex: Int(env["READER_SELFTEST_DOC"] ?? "0") ?? 0)
        }
    }

    private static let traceURL = ProcessInfo.processInfo.environment["READER_SELFTEST_LOG"].map { URL(fileURLWithPath: $0) }

    /// Diagnostic line in the self-test log (no-op unless a self-test is running).
    static func trace(_ message: @autoclosure () -> String) {
        guard let traceURL else { return }
        log(traceURL, ["trace": message(), "t": Date().timeIntervalSince1970])
    }

    private static func log(_ url: URL, _ fields: [String: Any]) {
        var line = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: url) }
    }

    private static func waitFor(timeout: Double = 20, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Waits until the action's restore has been applied, then for things to stay put.
    private static func settle(_ model: ReaderModel, after token: Int) async -> Bool {
        let start = Date()
        let ok = await waitFor { model.controller.restoreToken > token && model.state.phase == .reading && model.probe != nil }
        try? await Task.sleep(for: .milliseconds(1500)) // pages loading above must not move the reader
        trace("settled ok=\(ok) after \(Int(Date().timeIntervalSince(start) * 1000))ms phase=\(model.state.phase)")
        return ok
    }

    private static func run(step: String, log url: URL, docIndex: Int) async {
        let graph = AppGraph.shared
        trace("selftest \(step) started pid=\(ProcessInfo.processInfo.processIdentifier)")
        await accountSteps(log: url)
        if await !waitFor({ graph.openMainWindow != nil }) { trace("selftest: library window never appeared") }
        if let book = ProcessInfo.processInfo.environment["READER_SELFTEST_IMPORT"], !book.isEmpty {
            graph.open(urls: [URL(fileURLWithPath: book)])
        }
        if ProcessInfo.processInfo.environment["READER_SELFTEST_WAIT_SYNC"] == "1" {
            // A book added on another device: wait for the library sync to bring it here.
            let synced = await waitFor(timeout: 30) { ((try? graph.documents.library()) ?? []).count > 0 }
            log(url, ["step": step, "what": "librarySynced", "ok": synced,
                      "books": ((try? graph.documents.library()) ?? []).map(\.title).joined(separator: "|"),
                      "onLibrary": graph.navigation.path.isEmpty,
                      "windows": NSApp.windows.filter { $0.isVisible }.map { $0.title }.joined(separator: "|")])
        }
        guard let rows = try? graph.documents.library(), docIndex < rows.count else {
            log(url, ["step": step, "error": "no book"]); return
        }
        // Reopen the same book each run (rows are ordered by last opened).
        let id = rows.sorted { $0.id < $1.id }[docIndex].id
        graph.show(id)
        trace("selftest: showing \(id.prefix(8)); open readers: \(graph.model(for: id) != nil)")
        guard await waitFor({ graph.model(for: id)?.probe != nil }), let model = graph.model(for: id) else {
            log(url, ["step": step, "error": "window didn't open"]); return
        }
        _ = await waitFor { model.state.phase == .reading }
        try? await Task.sleep(for: .milliseconds(500))
        func record(_ what: String, _ extra: [String: Any] = [:]) {
            let m = model.probe!.probeMeasure()
            let saved = try? graph.positions.load(id)
            var f: [String: Any] = ["step": step, "what": what, "page": m.page, "fraction": Double(m.fraction),
                                    "mode": model.state.mode.rawValue, "zoom": Double(model.state.zoom),
                                    "textScale": Double(model.state.textScale),
                                    "width": Int(model.probe!.probeWindow?.frame.width ?? 0),
                                    "savedPage": saved?.pageIndex ?? -1, "savedFraction": Double(saved?.pageOffset ?? -1),
                                    "notice": String(describing: model.state.notice)]
            f.merge(extra) { a, _ in a }
            log(url, f)
        }
        record("opened", ["windows": NSApp.windows.filter { $0.isVisible }.map { $0.title }.joined(separator: "|"), "telemetry2": "", "telemetry": graph.telemetry.counts().filter { $0.value > 0 }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")])

        switch step {
        case "read":
            // Scroll in several moves like a reader would, ending on page 187 (index 186), halfway.
            let target = Int(ProcessInfo.processInfo.environment["READER_SELFTEST_PAGE"] ?? "186") ?? 186
            for p in stride(from: max(0, target - 30), through: target, by: 10) {
                model.probe!.probeScroll(page: p, fraction: 0.2)
                try? await Task.sleep(for: .milliseconds(80))
            }
            model.probe!.probeScroll(page: target, fraction: 0.5)
            try? await Task.sleep(for: .milliseconds(900)) // debounce elapses; no flush is called
            record("scrolled")
        case "ocr":
            // Scanned pages 50-51 and the figure page 100 of the generated sample book.
            model.setMode(.text)
            for page in [49, 50, 99] {
                let t = model.controller.restoreToken
                model.goToPage(page)
                _ = await settle(model, after: t)
                _ = await waitFor { model.text?.loaded[page] != nil }
                let text = model.text?.loaded[page]
                record("page", ["checked": page, "recognized": text?.recognized ?? false, "blocks": text?.blocks.count ?? -1,
                                "start": String((text?.blocks.first?.text ?? "").prefix(60)),
                                "banner": model.topPageRecognized])
            }
        case "views":
            try? await Task.sleep(for: .seconds(2))
            if let flow = model.probe as? FlowCoordinator { record("views", flow.probePageInfo()) }
            let shots = ProcessInfo.processInfo.environment["READER_SELFTEST_SHOTS"] ?? "/tmp"
            func grab(_ name: String) {
                guard let window = model.probe?.probeWindow,
                      let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming])
                else { return }
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shots + "/" + name))
            }
            grab("open.png")
            if let flow = model.probe as? FlowCoordinator {
                flow.turnPage(forward: true)
                try? await Task.sleep(for: .seconds(1.5))
                record("viewsAfterTurn", flow.probePageInfo())
                grab("turned.png")
            }
        case "observe":
            // A late answer from the server lands after the initial restore.
            try? await Task.sleep(for: .seconds(3))
            record("observed", ["telemetry": graph.telemetry.counts().filter { $0.value > 0 }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")])
        case "paging":
            // Page by page: five pages forward, then five back to the same place.
            if model.pdf != nil {
                let t = model.controller.restoreToken
                model.setMode(.text)
                _ = await settle(model, after: t)
            }
            model.setFlowLayout(.paged)
            try? await Task.sleep(for: .milliseconds(300))
            guard let flow = model.probe as? FlowCoordinator else { break }
            record("pageStart", flow.probePageInfo())
            for _ in 0..<5 {
                flow.turnPage(forward: true)
                try? await Task.sleep(for: .milliseconds(200))
                record("turnedForward", flow.probePageInfo())
            }
            for _ in 0..<5 {
                flow.turnPage(forward: false)
                try? await Task.sleep(for: .milliseconds(200))
                record("turnedBack", flow.probePageInfo())
            }
            try? await Task.sleep(for: .milliseconds(900))
            record("pagingDone")
        case "spread":
            // Two pages side by side, each theme, and page turns both ways; snapshots in
            // READER_SELFTEST_SHOTS.
            let shots = ProcessInfo.processInfo.environment["READER_SELFTEST_SHOTS"].map { URL(fileURLWithPath: $0) }
            if model.pdf != nil, let pages = model.probe as? PagesCoordinator {
                for spread in [PageSpread.single, .double] {
                    let t = model.controller.restoreToken
                    model.setSpread(spread)
                    _ = await settle(model, after: t)
                    record("pagesSpread", ["spread": spread.rawValue])
                    if let shots { pages.probeSave(shots.appendingPathComponent("pages-\(spread.rawValue.lowercased()).png")) }
                    let before = model.state.pageIndex
                    let t2 = model.controller.restoreToken
                    model.nextPage()
                    _ = await settle(model, after: t2)
                    record("pagesNext", ["spread": spread.rawValue, "from": before])
                }
            }
            if model.pdf != nil {
                let t = model.controller.restoreToken
                model.setMode(.text)
                _ = await settle(model, after: t)
            }
            model.setFlowLayout(.paged)
            if let window = model.probe?.probeWindow {
                var f = window.frame
                f.size = NSSize(width: 1300, height: 860)
                window.setFrame(f, display: true)
            }
            for spread in [PageSpread.single, .double] {
                let t = model.controller.restoreToken
                model.setSpread(spread)
                _ = await settle(model, after: t)
                guard let flow = model.probe as? FlowCoordinator else { break }
                for theme in TextTheme.allCases {
                    model.setTheme(theme)
                    try? await Task.sleep(for: .milliseconds(400))
                    if let shots { flow.probeSave(shots.appendingPathComponent("\(spread.rawValue.lowercased())-\(theme.rawValue.lowercased()).png")) }
                }
                record("spread", flow.probePageInfo().merging(["spread": spread.rawValue]) { a, _ in a })
                for _ in 0..<3 {
                    flow.turnPage(forward: true)
                    try? await Task.sleep(for: .milliseconds(500))
                    record("turnedForward", flow.probePageInfo().merging(["spread": spread.rawValue]) { a, _ in a })
                }
                for _ in 0..<3 {
                    flow.turnPage(forward: false)
                    try? await Task.sleep(for: .milliseconds(500))
                    record("turnedBack", flow.probePageInfo().merging(["spread": spread.rawValue]) { a, _ in a })
                }
            }
            graph.showLibrary()
            try? await Task.sleep(for: .milliseconds(800))
            log(url, ["step": step, "what": "backToLibrary", "onLibrary": graph.navigation.path.isEmpty,
                      "readerClosed": graph.model(for: id) == nil])
        case "resize", "zoom", "mode", "textsize", "all":
            await relayoutChecks(step, model, record)
        default:
            break
        }
        // READER_SELFTEST_LINGER: stay open like a reader would, so background uploads run.
        let linger = Double(ProcessInfo.processInfo.environment["READER_SELFTEST_LINGER"] ?? "1") ?? 1
        try? await Task.sleep(for: .seconds(linger))
        log(url, ["step": step, "what": "done", "pending": (try? graph.positions.pending().count) ?? -1, "windows": NSApp.windows.filter { $0.isVisible }.map { "\($0.title)[\(type(of: $0)) \(Int($0.frame.width))x\(Int($0.frame.height)) lvl\($0.level.rawValue)]" }.joined(separator: "|")])
    }

    /// READER_SELFTEST_SIGNUP / READER_SELFTEST_SIGNIN = "email:password": the account flows the
    /// Settings window runs, with the emailed code read from the dev server's READER_DEV_MAIL_DIR.
    private static func accountSteps(log url: URL) async {
        let env = ProcessInfo.processInfo.environment
        let account = AppGraph.shared.account
        func split(_ v: String) -> (String, String) {
            let i = v.firstIndex(of: ":")!
            return (String(v[..<i]), String(v[v.index(after: i)...]))
        }
        func latestCode(for email: String) async -> String? {
            guard let dir = env["READER_DEV_MAIL_DIR"] else { return nil }
            for _ in 0..<50 {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix("-\(email).json") }.sorted() ?? []
                if let last = files.last, let data = FileManager.default.contents(atPath: dir + "/" + last),
                   let mail = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = mail["text"] as? String,
                   let range = text.range(of: #"\b\d{6}\b"#, options: .regularExpression) {
                    return String(text[range])
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
        do {
            if let v = env["READER_SELFTEST_SIGNUP"] {
                let (email, password) = split(v)
                try await account.createAccount(email: email, password: password)
                guard let code = await latestCode(for: email) else { throw AccountError(code: "test", message: "no code emailed") }
                try await account.confirm(code: code)
            } else if let v = env["READER_SELFTEST_SIGNIN"] {
                let (email, password) = split(v)
                try await account.signIn(email: email, password: password)
            } else {
                return
            }
            log(url, ["account": account.email ?? "", "signedIn": account.isSignedIn])
        } catch {
            log(url, ["account": "error", "error": (error as? LocalizedError)?.errorDescription ?? "\(error)"])
        }
    }

    private static func relayoutChecks(_ step: String, _ model: ReaderModel, _ record: (String, [String: Any]) -> Void) async {
        guard let window = model.probe?.probeWindow else { return }
        var t = 0
        if step == "resize" || step == "all" {
            for width in [560.0, 1300.0, 820.0] {
                var f = window.frame
                f.size.width = width
                t = model.controller.restoreToken
                window.setFrame(f, display: true)
                _ = await settle(model, after: t)
                record("resized", [:])
            }
        }
        if (step == "zoom" || step == "all") && model.pdf != nil && model.state.mode == .pages {
            t = model.controller.restoreToken
            model.zoomIn(); model.zoomIn()
            _ = await settle(model, after: t)
            record("zoomedIn", [:])
            t = model.controller.restoreToken
            model.actualSize()
            _ = await settle(model, after: t)
            record("zoomReset", [:])
        }
        if (step == "mode" || step == "all") && model.pdf != nil {
            t = model.controller.restoreToken
            model.setMode(.text)
            _ = await settle(model, after: t)
            try? await Task.sleep(for: .milliseconds(800))
            record("flowingText", [:])
            if step == "all" {
                t = model.controller.restoreToken
                model.zoomIn(); model.zoomIn()
                _ = await settle(model, after: t)
                record("largerText", [:])
                t = model.controller.restoreToken
                model.setTextScale(1)
                _ = await settle(model, after: t)
            }
            t = model.controller.restoreToken
            model.setMode(.pages)
            _ = await settle(model, after: t)
            record("originalPages", [:])
        }
        if step == "textsize" || (step == "all" && model.epub != nil) {
            t = model.controller.restoreToken
            model.zoomIn(); model.zoomIn()
            _ = await settle(model, after: t)
            record("largerText", [:])
            t = model.controller.restoreToken
            model.setTextScale(1)
            _ = await settle(model, after: t)
            record("defaultText", [:])
        }
    }
}
