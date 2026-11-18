import AppKit

/// 사이트 권한 창(사용자 결정 2026-11-18 「만들기」) — Chromium 이 출처마다 기억한 허용·차단을 보고 하나씩 지운다(지우면 그 사이트는 다시 묻는다).
/// 앱 전역 창 하나, 앱 메뉴 「Site Permissions…」 가 연다(「Browser Grants」 바로 아래 — 「누가 무엇을 할 수 있나」 를 되돌리는 자리). 표는 Zig 가
/// 쥐고(`web_osr` — ABI `maru_macos_site_permissions_*`), 이 창은 세대가 바뀌면 다시 읽어 그린다. 사람의 답과 에이전트의 답은 같은 자리에 같은
/// 모양이라(Chromium 이 가르지 않는다) 똑같이 보인다. 문장은 Zig i18n 이 고른다(docs/i18n.md §7.2).
/// 이 창은 터미널 창이 아니다 — 컨트롤러는 이 창이 키일 때 메뉴의 터미널 동작을 막는다(⌘W 는 이 창을 닫는다).
final class SitePermissionsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    struct Row: Equatable {
        let kind: UInt32
        let setting: UInt32
        let origin: String
        let display: String
        let label: String
    }

    /// `web_osr.SitePermState` 와 같은 값.
    enum State: UInt32 { case idle = 0, waiting, ready, engineOff }

    let window: NSWindow
    private let table = NSTableView()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private(set) var rows: [Row] = []
    private(set) var state: State = .idle
    private(set) var generation: UInt64 = 0
    /// 사람이 그 행의 「지우기」 를 눌렀다 — 컨트롤러가 (종류, 출처)로 ABI 에 넘긴다.
    var onRemove: ((Row) -> Void)?
    /// 창이 앞으로 왔다 — 컨트롤러가 목록을 다시 묻는다.
    var onBecameKey: (() -> Void)?
    private let text: (UInt32) -> String

    init(text: @escaping (UInt32) -> String) {
        self.text = text
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        super.init()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 240)
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MaruSitePermissions")

        for (id, width) in [("site", 200.0), ("permission", 140.0), ("decision", 56.0), ("remove", 80.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            column.minWidth = id == "site" ? 140 : 60
            column.resizingMask = id == "site" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.rowHeight = 26
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        if #available(macOS 11.0, *) { table.style = .inset }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.maximumNumberOfLines = 3
        noteLabel.preferredMaxLayoutWidth = 560
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.alignment = .center
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = BackgroundView()
        content.addSubview(noteLabel)
        content.addSubview(scroll)
        content.addSubview(stateLabel)
        content.addSubview(footerLabel)
        NSLayoutConstraint.activate([
            noteLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            noteLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            noteLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -6),
            footerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            footerLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            stateLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        window.contentView = content
        updateChrome(footer: "")
    }

    /// 세대가 바뀌었으면 행·상태를 다시 받는다.
    func update(generation: UInt64, state newState: State, rows newRows: [Row], footer: String) {
        self.generation = generation
        state = newState
        if newRows != rows {
            rows = newRows
            table.reloadData()
        }
        updateChrome(footer: footer)
    }

    func showFront() {
        window.makeKeyAndOrderFront(nil)
    }

    private func updateChrome(footer: String) {
        // 실행 중 UI 언어를 바꿀 수 있다 — 글은 Zig 에서 다시 받는다.
        window.title = text(0)
        noteLabel.stringValue = text(9)
        for (index, id) in [1, 2].enumerated() { table.tableColumns[index].title = text(UInt32(id)) }
        table.tableColumns[2].title = ""
        table.tableColumns[3].title = ""
        footerLabel.stringValue = footer
        switch state {
        case .engineOff: stateLabel.stringValue = text(7)
        case .waiting where rows.isEmpty, .idle: stateLabel.stringValue = text(8)
        case .ready where rows.isEmpty: stateLabel.stringValue = text(6)
        default: stateLabel.stringValue = ""
        }
        stateLabel.isHidden = stateLabel.stringValue.isEmpty
    }

    // ── 표 ──
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let column = tableColumn?.identifier.rawValue else { return nil }
        let r = rows[row]
        if column == "remove" {
            let button = NSButton(title: text(5), target: self, action: #selector(removeRow(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = row
            return button
        }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        switch column {
        case "site":
            field.stringValue = r.display
            field.toolTip = r.origin
        case "permission":
            field.stringValue = r.label
        default:
            let allowed = r.setting == 1
            field.stringValue = text(allowed ? 3 : 4)
            field.textColor = allowed ? .systemGreen : .systemRed
        }
        return field
    }

    @objc private func removeRow(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < rows.count else { return }
        onRemove?(rows[index])
    }

    func windowDidResize(_ notification: Notification) {
        _ = notification
        noteLabel.preferredMaxLayoutWidth = max(200, window.contentLayoutRect.width - 28)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        _ = notification
        onBecameKey?()
    }

    // ── 시험 전용 ──
    /// 창 내용을 PNG 로(화면을 찍지 않는다 — 창 view 를 그린다) — 대본 `sitepermsnap`.
    func testSnapshot(to path: String) -> Bool {
        guard window.isVisible, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// 그 행의 「지우기」 를 누른 것처럼 — 대본 `sitepermreset`.
    func testRemove(index: Int) -> Bool {
        guard index >= 0, index < rows.count else { return false }
        onRemove?(rows[index])
        return true
    }
}

/// 창 배경을 스스로 칠하는 내용 view — 시험 대본의 캡처(`cacheDisplay`)에도 창과 같은 배경이 담기게.
private final class BackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
