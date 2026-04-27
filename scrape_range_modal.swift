import ApplicationServices
import AppKit
import Foundation

struct ScheduleRow {
    let time: String
    let detail: String
}

struct CsvRow {
    var date: String
    var start: String
    var end: String
    var customer: String
    var staff: String
    var type: String
    var memo: String
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

func desc(_ element: AXUIElement) -> String {
    attr(element, kAXDescriptionAttribute as String) ?? ""
}

func text(_ element: AXUIElement) -> String {
    let t = title(element)
    if !t.isEmpty { return t }
    let v = value(element)
    if !v.isEmpty { return v }
    return desc(element)
}

func focusedWindow() throws -> AXUIElement {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.perplexity.comet").first else {
        throw NSError(domain: "scrape", code: 1)
    }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let window: AXUIElement = attr(axApp, kAXFocusedWindowAttribute as String) else {
        throw NSError(domain: "scrape", code: 2)
    }
    return window
}

func findElement(_ root: AXUIElement, _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if predicate(root) { return root }
    for child in children(root) {
        if let found = findElement(child, predicate) { return found }
    }
    return nil
}

func findAll(_ root: AXUIElement, _ predicate: (AXUIElement) -> Bool, into result: inout [AXUIElement]) {
    if predicate(root) { result.append(root) }
    for child in children(root) {
        findAll(child, predicate, into: &result)
    }
}

func parent(_ element: AXUIElement) -> AXUIElement? {
    attr(element, kAXParentAttribute as String)
}

func flattenTexts(_ root: AXUIElement) -> [String] {
    var out: [String] = []
    if ["AXStaticText", "AXTextField", "AXButton", "AXLink", "AXHeading", "AXPopUpButton"].contains(role(root)) {
        let current = text(root)
        if !current.isEmpty { out.append(current) }
    }
    for child in children(root) {
        out.append(contentsOf: flattenTexts(child))
    }
    return out
}

func buttonExists(_ name: String) -> Bool {
    guard let window = try? focusedWindow() else { return false }
    return findElement(window, { role($0) == "AXButton" && title($0) == name }) != nil
}

func pressButton(_ name: String) throws {
    let window = try focusedWindow()
    guard let button = findElement(window, { role($0) == "AXButton" && title($0) == name }) else {
        throw NSError(domain: "scrape", code: 3, userInfo: [NSLocalizedDescriptionKey: "Button not found \(name)"])
    }
    AXUIElementPerformAction(button, kAXPressAction as CFString)
    usleep(300_000)
}

func sendEscape() {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    usleep(250_000)
}

func dismissTransient() {
    for _ in 0..<4 {
        if buttonExists("취소") {
            try? pressButton("취소")
        } else if buttonExists("단일 케이스") || buttonExists("정규 일정") {
            sendEscape()
        } else {
            return
        }
    }
}

func headingText() -> String {
    guard let window = try? focusedWindow(),
          let heading = findElement(window, {
              role($0) == "AXHeading"
                  && title($0).contains("2026년")
                  && title($0).contains("월")
          }) else { return "" }
    return title(heading)
}

func dayNumber(_ heading: String) -> Int {
    let range = heading.range(of: #"(\d+)일"#, options: .regularExpression)
    let text = range.map { String(heading[$0]).replacingOccurrences(of: "일", with: "") } ?? ""
    return Int(text) ?? 0
}

func ensureDayList() throws {
    let heading = headingText()
    if heading.contains("일") && heading != "2026년 3월" { return }
    try pressButton("일 리스트")
}

func ensureDay(_ target: String) throws {
    dismissTransient()
    try ensureDayList()
    while headingText() != target {
        let current = headingText()
        try pressButton(dayNumber(current) > dayNumber(target) ? "‹" : "›")
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline && headingText() == current {
            usleep(100_000)
        }
    }
}

func scheduleRows() throws -> [ScheduleRow] {
    let window = try focusedWindow()
    var elements: [AXUIElement] = []
    findAll(window, { role($0) == "AXRow" }, into: &elements)
    var seen = Set<String>()
    return elements.compactMap { row in
        let texts = flattenTexts(row)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard texts.count >= 2, texts[0].first?.isNumber == true else { return nil }
        let key = "\(texts[0])\t\(texts[1])"
        guard !seen.contains(key) else { return nil }
        seen.insert(key)
        return ScheduleRow(time: texts[0], detail: texts[1])
    }
}

func findScheduleElement(time: String, detail: String) throws -> AXUIElement? {
    let window = try focusedWindow()
    var elements: [AXUIElement] = []
    findAll(window, { role($0) == "AXRow" }, into: &elements)
    return elements.first { row in
        let texts = flattenTexts(row)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return texts.count >= 2 && texts[0] == time && texts[1] == detail
    }
}

func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2.0) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(100_000)
    }
    return false
}

func textField(_ label: String, in root: AXUIElement? = nil) -> AXUIElement? {
    let root = root ?? (try? focusedWindow())
    guard let root else { return nil }
    return findElement(root, { role($0) == "AXTextField" && title($0) == label })
}

func modalRoot() -> AXUIElement? {
    guard let dateField = textField("날짜") else { return nil }
    var current: AXUIElement? = dateField
    var result: AXUIElement?
    while let node = current {
        if result == nil && findElement(node, { role($0) == "AXButton" && title($0) == "취소" }) != nil {
            result = node
        }
        current = parent(node)
    }
    return result
}

func popups(in root: AXUIElement) -> [String] {
    var result: [AXUIElement] = []
    findAll(root, { role($0) == "AXPopUpButton" }, into: &result)
    return result.map { text($0) }.filter { !$0.isEmpty }
}

func field(_ texts: [String], _ prefix: String) -> String {
    texts.last(where: { $0.hasPrefix(prefix) })?
        .replacingOccurrences(of: prefix, with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func cleanTime(_ input: String) -> String {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let range = text.range(of: #"\d{4}-\d{2}-\d{2}\s+(\d{1,2}:\d{2})"#, options: .regularExpression) {
        return String(text[range]).split(separator: " ").last.map(String.init) ?? text
    }
    return text
}

func stripParen(_ input: String) -> String {
    if let index = input.firstIndex(of: "(") {
        return String(input[..<index]).trimmingCharacters(in: .whitespaces)
    }
    return input.trimmingCharacters(in: .whitespaces)
}

func padTime(_ input: String) -> String {
    let parts = input.split(separator: ":")
    if parts.count == 2, let hour = Int(parts[0]) {
        return String(format: "%02d:%@", hour, String(parts[1]))
    }
    return input
}

func csvEscape(_ input: String) -> String {
    if input.contains(",") || input.contains("\"") || input.contains("\n") || input.contains("\r") {
        return "\"" + input.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return input
}

func parseDetail(_ detail: String) -> (customer: String, staff: String, memo: String) {
    guard let dash = detail.firstIndex(of: "-"),
          let open = detail.firstIndex(of: "("),
          let close = detail.firstIndex(of: ")") else {
        return ("", "", "")
    }
    return (
        String(detail[..<dash]),
        String(detail[detail.index(after: dash)..<open]),
        String(detail[detail.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    )
}

func openRow(time: String, detail: String) throws {
    dismissTransient()
    guard let row = try findScheduleElement(time: time, detail: detail) else {
        throw NSError(domain: "scrape", code: 4, userInfo: [NSLocalizedDescriptionKey: "Row not found \(time) \(detail)"])
    }
    for candidate in [row] + children(row) {
        if AXUIElementPerformAction(candidate, kAXPressAction as CFString) == .success {
            usleep(300_000)
            if waitUntil({
                buttonExists("단일 케이스")
                    || buttonExists("취소")
                    || (try? focusedWindow()).map { flattenTexts($0).contains(where: { $0.hasPrefix("시작:") }) } == true
            }, timeout: 1.8) {
                return
            }
        }
    }
}

func scrapeRow(date: String, time: String, detail: String) throws -> CsvRow {
    try openRow(time: time, detail: detail)
    if buttonExists("단일 케이스") {
        try pressButton("단일 케이스")
        _ = waitUntil({ buttonExists("취소") }, timeout: 2.0)
    }

    let fallback = parseDetail(detail)
    var row = CsvRow(date: date, start: time, end: "", customer: fallback.customer, staff: fallback.staff, type: "", memo: fallback.memo)

    if let root = modalRoot(), buttonExists("취소") {
        let values = popups(in: root)
        if values.count >= 3 {
            row.customer = values[0]
            row.staff = values[1]
            row.type = values[2]
        }
        row.start = value(textField("시작시간", in: root) ?? AXUIElementCreateSystemWide())
        row.end = value(textField("종료시간", in: root) ?? AXUIElementCreateSystemWide())
        let memo = value(textField("메모", in: root) ?? AXUIElementCreateSystemWide())
        if !memo.isEmpty { row.memo = memo }
        try pressButton("취소")
        return row
    }

    let texts = flattenTexts(try focusedWindow())
    row.start = cleanTime(field(texts, "시작:"))
    row.end = cleanTime(field(texts, "종료:"))
    row.customer = stripParen(field(texts, "고객:"))
    row.staff = stripParen(field(texts, "인력:"))
    row.type = field(texts, "유형:")
    dismissTransient()
    return row
}

func isoDate(_ day: Int) -> String {
    String(format: "2026-03-%02d", day)
}

func writeCsv(rows: [CsvRow], to path: String) throws {
    let header = ["날짜", "시작시간", "종료시간", "고객", "담당인력", "유형", "메모"].joined(separator: ",")
    let lines = [header] + rows.map {
        [$0.date, padTime($0.start), padTime($0.end), $0.customer, $0.staff, $0.type, $0.memo]
            .map(csvEscape)
            .joined(separator: ",")
    }
    try (lines.joined(separator: "\n") + "\n")
        .write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
}

func scrapeDay(_ day: Int) throws -> (Int, Int) {
    let date = isoDate(day)
    try ensureDay("2026년 3월 \(day)일")
    let rows = try scheduleRows()
    var output: [CsvRow] = []
    for source in rows {
        let row = try scrapeRow(date: date, time: source.time, detail: source.detail)
        output.append(row)
    }
    try writeCsv(rows: output, to: "output/\(date).csv")
    print("\(date): \(output.count)/\(rows.count)")
    fflush(stdout)
    return (output.count, rows.count)
}

func main() throws {
    guard AXIsProcessTrusted() else {
        fputs("Accessibility access is required.\n", stderr)
        exit(1)
    }
    let args = CommandLine.arguments.dropFirst().compactMap { Int($0) }
    let start = args.first ?? 7
    let end = args.dropFirst().first ?? start
    var failures: [String] = []
    for day in start...end {
        let (captured, total) = try scrapeDay(day)
        if captured != total {
            failures.append("\(isoDate(day)) \(captured)/\(total)")
        }
        if day < end {
            try pressButton("›")
        }
    }
    if !failures.isEmpty {
        fputs("Incomplete: \(failures.joined(separator: ", "))\n", stderr)
        exit(2)
    }
}

do {
    try main()
} catch {
    fputs("Modal scrape failed: \(error)\n", stderr)
    exit(1)
}
