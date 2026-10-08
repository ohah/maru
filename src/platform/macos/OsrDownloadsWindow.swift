import AppKit
import UniformTypeIdentifiers

/// W10a: Chromium 탭의 다운로드 목록 창 — 앱 전역 창 하나(사용자 결정 2026-10-08 — Chrome 의 다운로드 목록처럼 진행 막대·취소·열기·
/// Finder 에서 보기). 목록과 상태는 Zig 가 쥐고(`web_downloads.zig` — ABI `maru_macos_downloads_*`), 이 창은 세대가 바뀌면 다시 읽어
/// 그린다. 문장은 Zig i18n 이 고른다(`maru_macos_downloads_text` — Swift 는 문장을 만들지 않는다, docs/i18n.md §7.2).
///
/// 행: 파일 아이콘·이름·상태 줄(받은 양 / 크기 — 크기를 모르면 받은 양만)·진행 막대(받는 중)·단추(받는 중: 취소, 중단: 다시 시도,
/// 보류: 받기·버리기, 끝남: Finder 에서 보기). 끝난 행을 두 번 누르면 연다 — 실행될 수 있는 파일은 열지 않고 Finder 에서 보인다.
/// 이 창은 터미널 창이 아니다 — 컨트롤러는 이 창이 키일 때 메뉴의 터미널 동작을 막는다(⌘W 는 이 창을 닫는다).
final class OsrDownloadsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    struct Row: Equatable {
        let key: UInt64
        let state: UInt32
        let risky: Bool
        let received: Int64
        let total: Int64
        let name: String
        let path: String
        /// 상태 줄 — Zig 가 만든 문장(받은 양·크기 포함).
        let status: String
    }

    /// `web_downloads.State` 와 같은 값.
    enum State: UInt32 {
        case preparing = 0, held, active, interrupted, done, canceled, failed, tabClosed, engineRestarted, tooMany
        /// W10b 매번 묻기 — 저장할 곳을 고르기를 기다린다.
        case asking
    }

    /// `maru_macos_downloads_act` 의 동작.
    enum Action: UInt32 {
        case cancel = 0, resumeDownload, accept, discard, remove
        /// W10b: 저장할 곳 고르기 — Zig `act` 로 가지 않고 컨트롤러가 이 창에 저장 창을 띄운다.
        case choose = 100
    }

    let window: NSWindow
    private let table = DoubleClickTable()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private(set) var rows: [Row] = []
    private(set) var seenGeneration: UInt64 = 0
    /// 사용자가 행에서 누른 것(키, 동작) — 컨트롤러가 ABI 로 넘긴다.
    var onAct: ((UInt64, Action) -> Void)?
    var onClearFinished: (() -> Void)?
    private let text: (UInt32) -> String

    init(text: @escaping (UInt32) -> String) {
        self.text = text
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = text(0)
        window.minSize = NSSize(width: 360, height: 220)
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MaruDownloads")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("download"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 58
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        if #available(macOS 11.0, *) { table.style = .inset }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openRow(_:))
        table.usesAlternatingRowBackgroundColors = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.stringValue = text(18)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        clearButton.title = text(17)
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearFinished(_:))
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(emptyLabel)
        content.addSubview(clearButton)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -8),
            clearButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            clearButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        window.contentView = content
        updateChrome()
    }

    /// 세대가 바뀌었으면 행을 다시 받는다.
    func update(generation: UInt64, rows newRows: [Row]) {
        seenGeneration = generation
        guard newRows != rows else { return }
        let sameShape = newRows.map(\.key) == rows.map(\.key)
        rows = newRows
        if sameShape {
            // 같은 행들의 진행만 바뀌었다 — 보이는 셀만 고친다(선택·스크롤을 지킨다).
            for index in 0..<rows.count {
                if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? DownloadCell {
                    configure(cell, rows[index])
                }
            }
        } else {
            // 이미 맨 아래를 보고 있었을 때만 새 행으로 내린다 — 다운로드를 계속 일으키는 페이지가 누르려던 행을 커서 아래에서 밀지
            // 않게(적대 리뷰 3 회차).
            let atBottom = table.visibleRect.maxY >= table.bounds.maxY - table.rowHeight
            table.reloadData()
            if atBottom, !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
        }
        updateChrome()
    }

    /// 앞으로 낸다 — `makeKey` 면 키 창으로(사용자가 직접 연 경우), 아니면 키를 빼앗지 않는다(새 다운로드가 시작됨).
    func showFront(makeKey: Bool) {
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    private func updateChrome() {
        // 실행 중 UI 언어를 바꿀 수 있다 — 창의 글도 Zig 에서 다시 받는다(적대 리뷰 3 회차).
        window.title = text(0)
        emptyLabel.stringValue = text(18)
        clearButton.title = text(17)
        emptyLabel.isHidden = !rows.isEmpty
        clearButton.isEnabled = rows.contains { Self.finished($0.state) }
    }

    static func finished(_ state: UInt32) -> Bool {
        guard let s = State(rawValue: state) else { return true }
        switch s {
        case .done, .canceled, .failed, .tabClosed, .engineRestarted, .tooMany: return true
        case .preparing, .held, .active, .interrupted, .asking: return false
        }
    }

    // ── 표 ──
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("download-cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? DownloadCell) ?? {
            let made = DownloadCell()
            made.identifier = id
            return made
        }()
        cell.owner = self
        configure(cell, rows[row])
        return cell
    }

    private func fileExists(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    private func configure(_ cell: DownloadCell, _ row: Row) {
        cell.key = row.key
        cell.nameField.stringValue = row.name
        let state = State(rawValue: row.state) ?? .failed
        let missing = state == .done && !fileExists(row.path)
        if fileExists(row.path) {
            cell.icon.image = NSWorkspace.shared.icon(forFile: row.path)
        } else if let type = UTType(filenameExtension: (row.name as NSString).pathExtension) {
            cell.icon.image = NSWorkspace.shared.icon(for: type)
        } else {
            cell.icon.image = NSWorkspace.shared.icon(for: .data)
        }
        // 문장은 Zig 가 만든다(docs/i18n.md §7.2) — 끝난 파일이 디스크에서 사라졌는지만 여기서 본다.
        cell.statusField.stringValue = missing ? text(11) : row.status
        cell.statusField.textColor = state == .held ? .systemOrange : .secondaryLabelColor
        let showProgress = state == .active || state == .interrupted || state == .preparing
        cell.progress.isHidden = !showProgress
        if showProgress {
            if row.total > 0 {
                cell.progress.isIndeterminate = false
                cell.progress.maxValue = Double(row.total)
                cell.progress.doubleValue = Double(min(row.received, row.total))
                cell.progress.stopAnimation(nil)
            } else {
                cell.progress.isIndeterminate = true
                cell.progress.startAnimation(nil)
            }
        } else {
            cell.progress.stopAnimation(nil)
        }
        // 단추 — (동작, 글) 둘까지.
        var buttons: [(Action?, String, Selector?)] = []
        switch state {
        case .preparing, .active: buttons = [(.cancel, text(12), nil)]
        case .interrupted: buttons = [(.resumeDownload, text(13), nil), (.cancel, text(12), nil)]
        case .held: buttons = [(.accept, text(14), nil), (.discard, text(15), nil)]
        case .asking: buttons = [(.choose, text(19), nil), (.cancel, text(12), nil)]
        case .done: buttons = missing ? [] : [(nil, text(16), #selector(revealRow(_:)))]
        // 받은 뒤 옮기지 못했다 — 받은 데이터는 행이 가리키는 임시 파일에 있다(적대 리뷰 2 회차).
        case .failed: buttons = fileExists(row.path) ? [(nil, text(16), #selector(revealRow(_:)))] : []
        default: buttons = []
        }
        // 단추는 모양이 바뀔 때만 새로 만든다 — 진행 갱신(초당 4 번)마다 만들면 누르는 사이 단추가 빠져 취소가 버려졌다(2 회차).
        cell.setButtons(buttons, target: self, signature: "\(row.key):\(row.state):\(missing):\(buttons.count):\(fileExists(row.path)):\(text(12))")
    }

    // ── 누름 ──
    @objc fileprivate func actButton(_ sender: NSButton) {
        guard let cell = sender.superview?.superview as? DownloadCell ?? sender.superview as? DownloadCell,
              let action = Action(rawValue: UInt32(sender.tag)) else { return }
        onAct?(cell.key, action)
    }

    @objc fileprivate func revealRow(_ sender: NSButton) {
        guard let cell = sender.superview?.superview as? DownloadCell ?? sender.superview as? DownloadCell,
              let row = rows.first(where: { $0.key == cell.key }), fileExists(row.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
    }

    /// 두 번 누르기 — 끝난 파일을 연다. 실행될 수 있는 파일은 열지 않고 Finder 에서 보인다.
    @objc private func openRow(_ sender: Any?) {
        let index = table.clickedRow
        guard index >= 0, index < rows.count else { return }
        let row = rows[index]
        guard State(rawValue: row.state) == .done, fileExists(row.path) else { return } // 실패 행(임시 파일)은 열지 않는다
        let url = URL(fileURLWithPath: row.path)
        if row.risky {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func clearFinished(_ sender: Any?) {
        onClearFinished?()
    }

    // ── 시험 전용 ──
    /// 창 내용을 PNG 로(화면을 찍지 않는다 — 창 view 를 그린다) — 대본 `dlwinsnap`.
    func testSnapshot(to path: String) -> Bool {
        guard window.isVisible, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// 그 행의 단추를 누른 것처럼(동작) — 대본 `dlact`.
    func testAct(index: Int, action: Action) -> Bool {
        guard index >= 0, index < rows.count else { return false }
        onAct?(rows[index].key, action)
        return true
    }
}

/// 두 번 누르기를 받는 표(창이 키가 아니어도 첫 누름을 받는다).
private final class DoubleClickTable: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class DownloadCell: NSTableCellView {
    var key: UInt64 = 0
    weak var owner: OsrDownloadsWindow?
    let icon = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    let statusField = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    private let buttonStack = NSStackView()

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameField.lineBreakMode = .byTruncatingMiddle
        statusField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.lineBreakMode = .byTruncatingTail
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 6
        for view in [icon, nameField, statusField, progress, buttonStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            nameField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -8),
            statusField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            statusField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),
            statusField.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -8),
            progress.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: buttonStack.leadingAnchor, constant: -8),
            progress.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 3),
            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    private var buttonSignature = ""

    func setButtons(_ buttons: [(OsrDownloadsWindow.Action?, String, Selector?)], target: OsrDownloadsWindow, signature: String) {
        guard signature != buttonSignature else { return }
        buttonSignature = signature
        for view in buttonStack.arrangedSubviews {
            buttonStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (action, title, selector) in buttons {
            let button = NSButton(title: title, target: target, action: selector ?? #selector(OsrDownloadsWindow.actButton(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = Int(action?.rawValue ?? 0)
            buttonStack.addArrangedSubview(button)
        }
    }
}
