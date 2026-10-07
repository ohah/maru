import AppKit

/// W6m②: Chromium 탭의 제안 목록(`<input list>` 의 datalist) — 칸 바로 아래에 띄우는 macOS 네이티브 창.
///
/// CEF windowless 는 페이지 픽셀만 넘긴다. Chrome 의 datalist 목록은 페이지가 아니라 브라우저 UI(자동 완성 팝업)라 CEF 에 없다 —
/// WebKit·Safari 처럼 키 초점을 갖지 않는 테두리 없는 자식 창 안의 표로 띄운다(사용자 결정 2026-10-07). 목록·강조는 Zig 가 쥐고
/// (`maru_macos_app_session_osr_datalist_*`), 이 창은 받은 대로 그리고 포인터만 알린다(`onHover`·`onPick`). 키(↑↓·Enter·Esc)는
/// 이 창이 아니라 maru 창이 받아 Zig 에 묻는다 — 초점은 페이지 칸에 남는다.
///
/// Chrome 154 실측(§7): 너비는 글 길이에 맞춘다(칸보다 좁을 수 있다), 높이는 묶이고 넘치면 스크롤, 값 옆에 레이블.
final class OsrDatalistPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Item: Equatable {
        let value: String
        let label: String
    }

    /// 창이 키·주 창이 되지 않게 — 초점은 maru 창(페이지 칸)에 남는다.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// 강조를 macOS 메뉴처럼 그린다(둥근 강조색 — 키 창이 아니어도 흐려지지 않는다).
    private final class RowView: NSTableRowView {
        override var isEmphasized: Bool {
            get { true }
            set {}
        }

        override func drawSelection(in dirtyRect: NSRect) {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
    }

    private final class Cell: NSTableCellView {
        let valueField = NSTextField(labelWithString: "")
        let labelField = NSTextField(labelWithString: "")

        init(font: NSFont) {
            super.init(frame: .zero)
            for field in [valueField, labelField] {
                field.font = font
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                addSubview(field)
            }
            valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labelField.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            labelField.alignment = .right
            NSLayoutConstraint.activate([
                valueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OsrDatalistPopup.textInset),
                valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
                labelField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OsrDatalistPopup.textInset),
                labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
                labelField.leadingAnchor.constraint(greaterThanOrEqualTo: valueField.trailingAnchor, constant: OsrDatalistPopup.labelGap),
            ])
            applyColors()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unused") }

        override var backgroundStyle: NSView.BackgroundStyle {
            didSet { applyColors() }
        }

        private func applyColors() {
            let selected = backgroundStyle == .emphasized
            valueField.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
            labelField.textColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        }
    }

    /// 포인터를 받는 표 — 키는 받지 않는다. 행 위에서 누르고 그 행에서 떼야 고른다(밖에서 떼면 고르지 않는다 — 목록은 남는다).
    /// 오른쪽·⌃ 누름은 삼킨다(목록에는 메뉴가 없다).
    private final class Table: NSTableView {
        weak var popup: OsrDatalistPopup?
        private var pressedRow = -1

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        private func rowAt(_ event: NSEvent) -> Int {
            row(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) { popup?.pointer(row: rowAt(event)) }
        override func mouseEntered(with event: NSEvent) { popup?.pointer(row: rowAt(event)) }
        override func mouseExited(with event: NSEvent) { popup?.pointer(row: -1) }

        override func mouseDown(with event: NSEvent) {
            pressedRow = event.modifierFlags.contains(.control) ? -1 : rowAt(event)
        }

        override func mouseDragged(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            let row = rowAt(event)
            defer { pressedRow = -1 }
            if pressedRow >= 0, row == pressedRow { popup?.pick(row: row) }
        }

        override func rightMouseDown(with event: NSEvent) {}
        override func otherMouseDown(with event: NSEvent) {}
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }

    static let rowHeight: CGFloat = 22
    static let maxVisibleRows = 9
    static let verticalPadding: CGFloat = 4
    static let textInset: CGFloat = 12
    static let labelGap: CGFloat = 16
    static let minWidth: CGFloat = 120

    /// 행 위 hover(행 번호 — -1 은 창을 떠남)와 행 고르기. 세대는 띄운 목록의 것.
    var onHover: ((UInt32, Int) -> Void)?
    var onPick: ((UInt32, Int) -> Void)?

    private let panel: Panel
    private let table = Table()
    private let scroll = NSScrollView()
    private let font = NSFont.menuFont(ofSize: 0)
    private weak var parent: NSWindow?
    private(set) var items: [Item] = []
    private(set) var generation: UInt32 = 0
    private(set) var selected = -1
    /// 마지막 자리 — 칸 아래(`below`)인가 위인가(판정 보고용).
    private(set) var placedBelow = true
    /// 칸(화면 좌표) — 판정 보고용.
    private(set) var fieldOnScreen = NSRect.zero

    var isShown: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    override init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: true)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        if #available(macOS 11.0, *) { table.style = .plain }
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.rowHeight = Self.rowHeight
        table.focusRingType = .none
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.popup = self

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: Self.verticalPadding),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -Self.verticalPadding),
        ])
    }

    /// 목록을 띄운다(이미 떠 있으면 고친다). `field` 는 칸의 화면 좌표. 목록이 바뀌었을 때만 항목을 다시 싣는다.
    func show(generation: UInt32, items: [Item], selected: Int, field: NSRect, parent: NSWindow) {
        let reload = generation != self.generation || items != self.items || !panel.isVisible
        self.generation = generation
        self.items = items
        fieldOnScreen = field
        if reload {
            table.reloadData()
            self.selected = -2 // 아래에서 다시 칠한다
        }
        let size = contentSize()
        place(size: size, field: field, screen: parent.screen ?? NSScreen.main)
        if self.parent !== parent {
            self.parent?.removeChildWindow(panel)
            self.parent = parent
        }
        panel.appearance = parent.effectiveAppearance
        if !panel.isVisible || panel.parent !== parent {
            parent.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
        setSelected(selected)
        if reload { panel.invalidateShadow() }
    }

    /// 거둔다.
    func hide() {
        guard panel.isVisible || parent != nil else { return }
        parent?.removeChildWindow(panel)
        parent = nil
        panel.orderOut(nil)
        selected = -1
    }

    /// 강조를 바꾼다(-1 = 없음). 보이게 굴린다 — 키로 옮긴 강조가 창 밖이면 따라간다.
    func setSelected(_ index: Int) {
        guard index != selected else { return }
        selected = index
        if index >= 0, index < items.count {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
        }
    }

    // ── 시험 전용(대본 `dlmouse`) — 진짜 사건 처리기를 그 행 가운데(-1 이면 창 밖) 자리의 합성 사건으로 부른다 ──
    func testMouse(row: Int, phase: String) -> Bool {
        guard panel.isVisible else { return false }
        let point: NSPoint
        if row >= 0, row < items.count {
            table.scrollRowToVisible(row)
            let rect = table.rect(ofRow: row)
            point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        } else {
            point = NSPoint(x: -40, y: -40)
        }
        let type: NSEvent.EventType
        switch phase {
        case "down": type = .leftMouseDown
        case "up": type = .leftMouseUp
        case "move": type = .mouseMoved
        default: type = .mouseMoved
        }
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
        switch phase {
        case "down": table.mouseDown(with: event)
        case "up": table.mouseUp(with: event)
        case "exit": table.mouseExited(with: event)
        default: table.mouseMoved(with: event)
        }
        return true
    }

    /// 시험 전용(대본 `dlsnap`) — 창 내용을 PNG 로(뒤 창을 비추는 배경은 빠진다 — 글·강조만 본다).
    func testSnapshot(to path: String) -> Bool {
        guard panel.isVisible, let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // ── 포인터(표가 부른다) ──
    fileprivate func pointer(row: Int) {
        onHover?(generation, row >= 0 && row < items.count ? row : -1)
    }

    fileprivate func pick(row: Int) {
        guard row >= 0, row < items.count else { return }
        onPick?(generation, row)
    }

    // ── 크기·자리 ──
    private func contentSize() -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var widest: CGFloat = 0
        for item in items {
            var w = ceil((item.value as NSString).size(withAttributes: attributes).width)
            if !item.label.isEmpty { w += Self.labelGap + ceil((item.label as NSString).size(withAttributes: attributes).width) }
            widest = max(widest, w)
        }
        let rows = min(items.count, Self.maxVisibleRows)
        let width = max(Self.minWidth, widest + Self.textInset * 2 + 4)
        return NSSize(width: width, height: CGFloat(rows) * Self.rowHeight + Self.verticalPadding * 2)
    }

    /// 칸 바로 아래, 왼쪽을 맞춘다. 화면 아래로 넘치면 칸 위로 올리고(위가 더 넓으면), 둘 다 좁으면 넓은 쪽에 높이를 줄여 둔다.
    /// 오른쪽으로 넘치면 왼쪽으로 민다.
    private func place(size: NSSize, field: NSRect, screen: NSScreen?) {
        let visible = screen?.visibleFrame ?? NSRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6)
        var width = min(size.width, max(visible.width, Self.minWidth))
        width = min(width, 600)
        let below = field.minY - visible.minY
        let above = visible.maxY - field.maxY
        var height = size.height
        placedBelow = below >= height || below >= above
        height = min(height, max(placedBelow ? below : above, Self.rowHeight + Self.verticalPadding * 2))
        var x = field.minX
        if x + width > visible.maxX { x = visible.maxX - width }
        x = max(x, visible.minX)
        let y = placedBelow ? field.minY - height : field.maxY
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        table.tableColumns.first?.width = width
    }

    // ── 표 ──
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("datalist-cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? Cell) ?? {
            let made = Cell(font: font)
            made.identifier = id
            return made
        }()
        let item = items[row]
        cell.valueField.stringValue = item.value
        cell.labelField.stringValue = item.label
        return cell
    }
}
