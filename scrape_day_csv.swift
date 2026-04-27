import ApplicationServices
import AppKit
import Foundation

struct SummaryInfo {
    var start: String = ""
    var end: String = ""
    var customer: String = ""
    var staff: String = ""
    var summaryType: String = ""
}

struct SingleInfo {
    var customer: String = ""
    var staff: String = ""
    var type: String = ""
    var date: String = ""
    var start: String = ""
    var end: String = ""
    var memo: String = ""
}

struct RegularInfo {
    var exists: Bool = false
    var staff: String = ""
    var type: String = ""
    var weekday: String = ""
    var applyStart: String = ""
    var start: String = ""
    var end: String = ""
    var weeks: String = ""
}

struct OutputRow {
    var date: String
    var listTime: String
    var listDetail: String
    var summary: SummaryInfo
    var single: SingleInfo
    var regular: RegularInfo
}

enum ScrapeError: Error {
    case appNotFound
    case focusedWindowNotFound
    case buttonNotFound(String)
    case rowNotFound(String)
    case popupNotFound
}

enum DetailOpenState {
    case chooser
    case singleDirect
    case regularDirect
}

func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return err == .success ? (value as? T) : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attr(element, kAXChildrenAttribute as String) ?? []
}

func role(_ element: AXUIElement) -> String {
    attr(element, kAXRoleAttribute as String) ?? ""
}

func title(_ element: AXUIElement) -> String {
    attr(element, kAXTitleAttribute as String) ?? ""
}

func value(_ element: AXUIElement) -> String {
    attr(element, kAXValueAttribute as String) ?? ""
}

func description(_ element: AXUIElement) -> String {
    attr(element, kAXDescriptionAttribute as String) ?? ""
}

func elementText(_ element: AXUIElement) -> String {
    let t = title(element)
    if !t.isEmpty { return t }
    let v = value(element)
    if !v.isEmpty { return v }
    return description(element)
}

func firstApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "ai.perplexity.comet").first
}

func focusedWindow() throws -> AXUIElement {
    guard let app = firstApp() else { throw ScrapeError.appNotFound }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let window: AXUIElement = attr(axApp, kAXFocusedWindowAttribute as String) else {
        throw ScrapeError.focusedWindowNotFound
    }
    return window
}

func findElement(_ root: AXUIElement, predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if predicate(root) { return root }
    for child in children(root) {
        if let found = findElement(child, predicate: predicate) {
            return found
        }
    }
    return nil
}

func findAll(_ root: AXUIElement, predicate: (AXUIElement) -> Bool, into result: inout [AXUIElement]) {
    if predicate(root) { result.append(root) }
    for child in children(root) {
        findAll(child, predicate: predicate, into: &result)
    }
}

func flattenTexts(_ root: AXUIElement) -> [String] {
    var out: [String] = []
    let r = role(root)
    if ["AXStaticText", "AXTextField", "AXButton", "AXLink", "AXHeading", "AXPopUpButton"].contains(r) {
        let text = elementText(root)
        if !text.isEmpty { out.append(text) }
    }
    for child in children(root) {
        out.append(contentsOf: flattenTexts(child))
    }
    return out
}

func sendKey(_ keyCode: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
    usleep(150_000)
}

func pressButton(named name: String) throws {
    let window = try focusedWindow()
    guard let button = findElement(window, predicate: { role($0) == "AXButton" && title($0) == name }) else {
        throw ScrapeError.buttonNotFound(name)
    }
    let err = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard err == .success else { throw ScrapeError.buttonNotFound(name) }
    usleep(250_000)
}

func buttonExists(_ name: String) -> Bool {
    guard let window = try? focusedWindow() else { return false }
    return findElement(window, predicate: { role($0) == "AXButton" && title($0) == name }) != nil
}

func dismissTransientUI() {
    for _ in 0..<3 {
        if buttonExists("취소") {
            try? pressButton(named: "취소")
            continue
        }
        if buttonExists("단일 케이스") || buttonExists("정규 일정") {
            sendKey(53)
            continue
        }
        break
    }
}

func headingText() -> String {
    guard let window = try? focusedWindow(),
          let heading = findElement(window, predicate: {
              let text = title($0)
              return role($0) == "AXHeading"
                  && text.contains("2026년")
                  && text.contains("월")
                  && (text.contains("일") || text == "2026년 3월")
          }) else {
        return ""
    }
    return title(heading)
}

func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 2.5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        usleep(120_000)
    }
    return false
}

func ensureDay(_ target: String) throws {
    dismissTransientUI()
    if !headingText().contains("일") {
        try pressButton(named: "일 리스트")
    }
    while headingText() != target {
        let current = headingText()
        let currentDay = Int(current.components(separatedBy: " ").last?.replacingOccurrences(of: "일", with: "") ?? "") ?? 0
        let targetDay = Int(target.components(separatedBy: " ").last?.replacingOccurrences(of: "일", with: "") ?? "") ?? 0
        try pressButton(named: currentDay > targetDay ? "‹" : "›")
        _ = waitUntil({ headingText() == target })
    }
}

func dayRows() throws -> [(AXUIElement, String, String)] {
    let window = try focusedWindow()
    var rows: [AXUIElement] = []
    findAll(window, predicate: { role($0) == "AXRow" }, into: &rows)
    return rows.compactMap { row in
        let texts = flattenTexts(row).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard texts.count >= 2, texts[0].first?.isNumber == true else { return nil }
        return (row, texts[0], texts[1])
    }
}

func openDetail(forTime time: String, detail: String) throws -> DetailOpenState {
    dismissTransientUI()
    let rows = try dayRows()
    guard let target = rows.first(where: { $0.1 == time && $0.2 == detail }) else {
        throw ScrapeError.rowNotFound("\(time) \(detail)")
    }
    let candidates = [target.0] + children(target.0)
    var opened = false
    for candidate in candidates {
        let err = AXUIElementPerformAction(candidate, kAXPressAction as CFString)
        if err == .success {
            let hasSummary = waitUntil({
                guard let window = try? focusedWindow() else { return false }
                return flattenTexts(window).contains(where: { $0.hasPrefix("시작:") })
            }, timeout: 1.5)
            if hasSummary && !buttonExists("단일 케이스") {
                try? pressButton(named: "상세보기")
            }
            if waitUntil({ textField(named: "날짜") != nil }, timeout: 1.5) {
                return .singleDirect
            }
            if waitUntil({ textField(named: "적용 시작일") != nil }, timeout: 1.5) {
                return .regularDirect
            }
            opened = waitUntil({ buttonExists("단일 케이스") && buttonExists("정규 일정") }, timeout: 2.0)
            if opened { return .chooser }
        }
    }
    throw ScrapeError.popupNotFound
}

func parseSummary() -> SummaryInfo {
    guard let window = try? focusedWindow() else { return SummaryInfo() }
    let texts = flattenTexts(window)
    var info = SummaryInfo()
    for text in texts {
        if text.hasPrefix("시작:") { info.start = text.replacingOccurrences(of: "시작:", with: "").trimmingCharacters(in: .whitespaces) }
        if text.hasPrefix("종료:") { info.end = text.replacingOccurrences(of: "종료:", with: "").trimmingCharacters(in: .whitespaces) }
        if text.hasPrefix("고객:") { info.customer = text.replacingOccurrences(of: "고객:", with: "").trimmingCharacters(in: .whitespaces) }
        if text.hasPrefix("인력:") { info.staff = text.replacingOccurrences(of: "인력:", with: "").trimmingCharacters(in: .whitespaces) }
        if text.hasPrefix("유형:") { info.summaryType = text.replacingOccurrences(of: "유형:", with: "").trimmingCharacters(in: .whitespaces) }
    }
    return info
}

func allPopupButtons() -> [AXUIElement] {
    guard let window = try? focusedWindow() else { return [] }
    var result: [AXUIElement] = []
    findAll(window, predicate: { role($0) == "AXPopUpButton" }, into: &result)
    return result
}

func popupButtons(in root: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []
    findAll(root, predicate: { role($0) == "AXPopUpButton" }, into: &result)
    return result
}

func textField(named name: String) -> AXUIElement? {
    guard let window = try? focusedWindow() else { return nil }
    return findElement(window, predicate: { role($0) == "AXTextField" && title($0) == name })
}

func modalRoot(containing element: AXUIElement) -> AXUIElement? {
    guard let window = try? focusedWindow() else { return nil }
    var current: AXUIElement? = element
    var candidate: AXUIElement? = nil
    while let node = current {
        if candidate == nil && findElement(node, predicate: { role($0) == "AXButton" && title($0) == "취소" }) != nil {
            candidate = node
        }
        current = findParent(of: node, in: window)
    }
    return candidate
}

func textField(named name: String, in root: AXUIElement?) -> AXUIElement? {
    guard let root else { return textField(named: name) }
    return findElement(root, predicate: { role($0) == "AXTextField" && title($0) == name })
}

func modalValueAfterLabel(_ label: String, in root: AXUIElement?) -> String {
    guard let root else { return "" }
    var labels: [AXUIElement] = []
    findAll(root, predicate: {
        role($0) == "AXStaticText" && elementText($0) == label
    }, into: &labels)

    for labelElement in labels {
        guard let parent = findParent(of: labelElement, in: root) else { continue }
        let siblings = children(parent)
        guard let idx = siblings.firstIndex(where: { $0 as AnyObject === labelElement as AnyObject }) else { continue }
        for sibling in siblings.suffix(from: idx + 1) {
            let texts = flattenTexts(sibling)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != label && !$0.contains("javascript:void") }
            if let value = texts.first { return value }
        }
    }

    let texts = flattenTexts(root)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    if let idx = texts.firstIndex(of: label), idx + 1 < texts.count {
        return texts[idx + 1]
    }
    return ""
}

func currentSingleInfo() -> SingleInfo {
    var info = SingleInfo()
    let root = modalRoot(containing: textField(named: "날짜") ?? AXUIElementCreateSystemWide())
    info.customer = modalValueAfterLabel("고객", in: root)
    info.staff = modalValueAfterLabel("담당 인력", in: root)
    info.type = modalValueAfterLabel("유형", in: root)
    info.date = value(textField(named: "날짜", in: root) ?? AXUIElementCreateSystemWide())
    info.start = value(textField(named: "시작시간", in: root) ?? AXUIElementCreateSystemWide())
    info.end = value(textField(named: "종료시간", in: root) ?? AXUIElementCreateSystemWide())
    info.memo = value(textField(named: "메모", in: root) ?? AXUIElementCreateSystemWide())
    return info
}

func currentRegularInfo() -> RegularInfo {
    var info = RegularInfo()
    info.exists = true
    let root = modalRoot(containing: textField(named: "적용 시작일") ?? AXUIElementCreateSystemWide())
    info.staff = modalValueAfterLabel("담당 인력", in: root)
    info.type = modalValueAfterLabel("유형", in: root)
    info.weekday = modalValueAfterLabel("요일", in: root)
    info.applyStart = value(textField(named: "적용 시작일", in: root) ?? AXUIElementCreateSystemWide())
    info.start = value(textField(named: "시작시간 주기", in: root) ?? AXUIElementCreateSystemWide())
    info.end = value(textField(named: "종료시간", in: root) ?? AXUIElementCreateSystemWide())

    guard let window = root ?? (try? focusedWindow()) else { return info }
    var checks: [AXUIElement] = []
    findAll(window, predicate: { role($0) == "AXCheckBox" }, into: &checks)
    var activeWeeks: [String] = []
    for checkbox in checks {
        guard let parent = findParent(of: checkbox, in: window) else { continue }
        let texts = flattenTexts(parent).filter { $0.contains("주차") }
        if value(checkbox) == "1", let week = texts.first {
            activeWeeks.append(week)
        }
    }
    info.weeks = activeWeeks.joined(separator: "|")
    return info
}

func findParent(of target: AXUIElement, in root: AXUIElement) -> AXUIElement? {
    if let parent: AXUIElement = attr(target, kAXParentAttribute as String) {
        return parent
    }
    for child in children(root) {
        if child as AnyObject === target as AnyObject { return root }
        if let found = findParent(of: target, in: child) { return found }
    }
    return nil
}

func csvEscape(_ input: String) -> String {
    let escaped = input.replacingOccurrences(of: "\"", with: "\"\"")
    return "\"\(escaped)\""
}

func writeCSV(rows: [OutputRow], to path: String) throws {
    var lines: [String] = []
    lines.append([
        "date","list_time","list_detail",
        "summary_start","summary_end","summary_customer","summary_staff","summary_type",
        "single_customer","single_staff","single_type","single_date","single_start","single_end","single_memo",
        "regular_exists","regular_staff","regular_type","regular_weekday","regular_apply_start","regular_start","regular_end","regular_weeks"
    ].joined(separator: ","))

    for row in rows {
        lines.append([
            row.date, row.listTime, row.listDetail,
            row.summary.start, row.summary.end, row.summary.customer, row.summary.staff, row.summary.summaryType,
            row.single.customer, row.single.staff, row.single.type, row.single.date, row.single.start, row.single.end, row.single.memo,
            row.regular.exists ? "Y" : "N", row.regular.staff, row.regular.type, row.regular.weekday, row.regular.applyStart, row.regular.start, row.regular.end, row.regular.weeks
        ].map(csvEscape).joined(separator: ","))
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

func scrapeRow(date: String, time: String, detail: String) throws -> OutputRow {
    let openState = try openDetail(forTime: time, detail: detail)
    let summary = parseSummary()
    var regular = RegularInfo()
    var single = SingleInfo()

    switch openState {
    case .singleDirect:
        single = currentSingleInfo()
        try pressButton(named: "취소")
    case .regularDirect:
        regular = currentRegularInfo()
        try pressButton(named: "취소")
    case .chooser:
        try pressButton(named: "단일 케이스")
        _ = waitUntil({ textField(named: "날짜") != nil })
        single = currentSingleInfo()
        try pressButton(named: "취소")

        let secondOpenState = try openDetail(forTime: time, detail: detail)
        if secondOpenState == .chooser {
            try pressButton(named: "정규 일정")
            if waitUntil({ textField(named: "적용 시작일") != nil }) {
                regular = currentRegularInfo()
                try pressButton(named: "취소")
            }
        } else if secondOpenState == .regularDirect {
            regular = currentRegularInfo()
            try pressButton(named: "취소")
        } else if secondOpenState == .singleDirect {
            try pressButton(named: "취소")
        }
    }

    dismissTransientUI()
    return OutputRow(date: date, listTime: time, listDetail: detail, summary: summary, single: single, regular: regular)
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    let targetDate = args.first ?? "2026년 3월 4일"
    let outputPath = args.dropFirst().first ?? "./output/day_details.csv"

    guard AXIsProcessTrusted() else {
        fputs("Accessibility access is required.\n", stderr)
        exit(1)
    }

    try ensureDay(targetDate)
    let rows = try dayRows()
    let parts = targetDate
        .replacingOccurrences(of: "년", with: "")
        .replacingOccurrences(of: "월", with: "")
        .replacingOccurrences(of: "일", with: "")
        .split(separator: " ")
        .compactMap { Int($0) }
    let isoDate = parts.count == 3 ? String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2]) : targetDate
    var outputRows: [OutputRow] = []
    for (_, time, detail) in rows {
        outputRows.append(try scrapeRow(date: isoDate, time: time, detail: detail))
    }
    try writeCSV(rows: outputRows, to: outputPath)
    print(outputPath)
}

do {
    try main()
} catch {
    fputs("CSV scrape failed: \(error)\n", stderr)
    exit(1)
}
