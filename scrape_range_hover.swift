import ApplicationServices
import AppKit
import Foundation

struct ScheduleRow {
    let element: AXUIElement
    let time: String
    let detail: String
}

struct CsvRow {
    let date: String
    let start: String
    let end: String
    let customer: String
    let staff: String
    let type: String
    let memo: String
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

func elementText(_ element: AXUIElement) -> String {
    let t = title(element)
    if !t.isEmpty { return t }
    let v = value(element)
    if !v.isEmpty { return v }
    return desc(element)
}

func focusedWindow() throws -> AXUIElement {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.perplexity.comet").first else {
        throw NSError(domain: "scrape", code: 1, userInfo: [NSLocalizedDescriptionKey: "Comet is not running"])
    }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let window: AXUIElement = attr(axApp, kAXFocusedWindowAttribute as String) else {
        throw NSError(domain: "scrape", code: 2, userInfo: [NSLocalizedDescriptionKey: "No focused Comet window"])
    }
    return window
}

func findElement(_ root: AXUIElement, _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if predicate(root) { return root }
    for child in children(root) {
        if let found = findElement(child, predicate) {
            return found
        }
    }
    return nil
}

func findAll(_ root: AXUIElement, _ predicate: (AXUIElement) -> Bool, into result: inout [AXUIElement]) {
    if predicate(root) { result.append(root) }
    for child in children(root) {
        findAll(child, predicate, into: &result)
    }
}

func flattenTexts(_ root: AXUIElement) -> [String] {
    var out: [String] = []
    if ["AXStaticText", "AXTextField", "AXButton", "AXLink", "AXHeading", "AXPopUpButton"].contains(role(root)) {
        let text = elementText(root)
        if !text.isEmpty { out.append(text) }
    }
    for child in children(root) {
        out.append(contentsOf: flattenTexts(child))
    }
    return out
}

func cgPoint(_ element: AXUIElement) -> CGPoint? {
    guard let axValue: AXValue = attr(element, kAXPositionAttribute as String) else { return nil }
    var point = CGPoint.zero
    AXValueGetValue(axValue, .cgPoint, &point)
    return point
}

func cgSize(_ element: AXUIElement) -> CGSize? {
    guard let axValue: AXValue = attr(element, kAXSizeAttribute as String) else { return nil }
    var size = CGSize.zero
    AXValueGetValue(axValue, .cgSize, &size)
    return size
}

func pressButton(_ name: String) throws {
    let window = try focusedWindow()
    guard let button = findElement(window, { role($0) == "AXButton" && title($0) == name }) else {
        throw NSError(domain: "scrape", code: 3, userInfo: [NSLocalizedDescriptionKey: "Button not found: \(name)"])
    }
    AXUIElementPerformAction(button, kAXPressAction as CFString)
    usleep(300_000)
}

func headingText() -> String {
    guard let window = try? focusedWindow(),
          let heading = findElement(window, {
              role($0) == "AXHeading"
                  && title($0).range(of: #"\d{4}년"#, options: .regularExpression) != nil
                  && title($0).contains("월")
          }) else {
        return ""
    }
    return title(heading)
}

func ensureDayList() throws {
    let heading = headingText()
    if heading.contains("일") {
        return
    }
    try pressButton("일 리스트")
}

func dayNumber(_ heading: String) -> Int {
    let match = heading.range(of: #"(\d+)일"#, options: .regularExpression)
    let text = match.map { String(heading[$0]).replacingOccurrences(of: "일", with: "") } ?? ""
    return Int(text) ?? 0
}

func dateParts(_ heading: String) -> (year: Int, month: Int, day: Int)? {
    guard let match = heading.range(of: #"(\d{4})년\s+(\d{1,2})월\s+(\d{1,2})일"#, options: .regularExpression) else {
        return nil
    }
    let text = String(heading[match])
    let numbers = text
        .replacingOccurrences(of: "년", with: "")
        .replacingOccurrences(of: "월", with: "")
        .replacingOccurrences(of: "일", with: "")
        .split(separator: " ")
        .compactMap { Int($0) }
    guard numbers.count == 3 else { return nil }
    return (numbers[0], numbers[1], numbers[2])
}

func compareDateHeading(_ lhs: String, _ rhs: String) -> Int {
    guard let left = dateParts(lhs), let right = dateParts(rhs) else {
        return dayNumber(lhs) - dayNumber(rhs)
    }
    if left.year != right.year { return left.year - right.year }
    if left.month != right.month { return left.month - right.month }
    return left.day - right.day
}

func ensureDay(_ targetHeading: String) throws {
    try ensureDayList()
    while headingText() != targetHeading {
        let current = headingText()
        guard !current.isEmpty else {
            throw NSError(domain: "scrape", code: 4, userInfo: [NSLocalizedDescriptionKey: "Date heading not found"])
        }
        let direction = compareDateHeading(current, targetHeading) > 0 ? "‹" : "›"
        try pressButton(direction)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline && headingText() == current {
            usleep(100_000)
        }
    }
}

func scheduleRows() throws -> [ScheduleRow] {
    let window = try focusedWindow()
    var rows: [AXUIElement] = []
    findAll(window, { role($0) == "AXRow" }, into: &rows)
    var seen = Set<String>()
    return rows.compactMap { row in
        let texts = flattenTexts(row)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard texts.count >= 2, texts[0].first?.isNumber == true else { return nil }
        let key = "\(texts[0])\t\(texts[1])"
        guard !seen.contains(key) else { return nil }
        seen.insert(key)
        return ScheduleRow(element: row, time: texts[0], detail: texts[1])
    }
}

func field(_ texts: [String], _ prefix: String) -> String {
    texts.last(where: { $0.hasPrefix(prefix) })?
        .replacingOccurrences(of: prefix, with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func cleanTime(_ input: String) -> String {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let match = text.range(of: #"\d{4}-\d{2}-\d{2}\s+(\d{1,2}:\d{2})"#, options: .regularExpression) {
        return String(text[match]).split(separator: " ").last.map(String.init) ?? text
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

func parseCsvLine(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    var index = line.startIndex
    while index < line.endIndex {
        let char = line[index]
        if char == "\"" {
            let next = line.index(after: index)
            if inQuotes && next < line.endIndex && line[next] == "\"" {
                current.append("\"")
                index = next
            } else {
                inQuotes.toggle()
            }
        } else if char == "," && !inQuotes {
            fields.append(current)
            current = ""
        } else {
            current.append(char)
        }
        index = line.index(after: index)
    }
    fields.append(current)
    return fields
}

func readExistingCsvRows(from path: String) -> [CsvRow] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").dropFirst().compactMap { rawLine in
        let fields = parseCsvLine(String(rawLine))
        guard fields.count == 7 else { return nil }
        return CsvRow(
            date: fields[0],
            start: fields[1],
            end: fields[2],
            customer: fields[3],
            staff: fields[4],
            type: fields[5],
            memo: fields[6]
        )
    }
}

func parseFallback(_ detail: String) -> (customer: String, staff: String, memo: String) {
    guard let dash = detail.firstIndex(of: "-"),
          let open = detail.firstIndex(of: "("),
          let close = detail.firstIndex(of: ")"),
          dash < open,
          open < close else {
        return ("", "", "")
    }
    let memoStart = detail.index(after: close)
    return (
        String(detail[..<dash]),
        String(detail[detail.index(after: dash)..<open]),
        memoStart < detail.endIndex ? String(detail[memoStart...]).trimmingCharacters(in: .whitespaces) : ""
    )
}

func rowHoverPoint(_ row: ScheduleRow) -> CGPoint? {
    let cells = children(row.element).filter { role($0) == "AXCell" }
    let target = cells.count > 1 ? cells[1] : row.element
    guard let point = cgPoint(target), let size = cgSize(target) else { return nil }
    return CGPoint(x: point.x + min(max(size.width * 0.22, 24), size.width - 8), y: point.y + size.height / 2)
}

func isLikelyVisible(_ point: CGPoint) -> Bool {
    guard let window = try? focusedWindow(),
          let windowPoint = cgPoint(window),
          let windowSize = cgSize(window) else {
        return true
    }
    let top = windowPoint.y + 110
    let bottom = windowPoint.y + windowSize.height - 80
    return point.y >= top && point.y <= bottom
}

func moveMouse(_ point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func sendKey(_ keyCode: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?
        .post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?
        .post(tap: .cghidEventTap)
    usleep(150_000)
}

func resetScrollPositions() {
    sendKey(115) // Home
    guard let window = try? focusedWindow(),
          let table = findElement(window, { role($0) == "AXTable" }),
          let tablePoint = cgPoint(table),
          let tableSize = cgSize(table) else {
        usleep(300_000)
        return
    }
    moveMouse(CGPoint(x: tablePoint.x + tableSize.width * 0.5, y: tablePoint.y + min(tableSize.height * 0.4, 220)))
    usleep(100_000)
    let source = CGEventSource(stateID: .hidSystemState)
    for _ in 0..<4 {
        AXUIElementPerformAction(table, "AXScrollUp" as CFString)
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: 1200, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
        usleep(120_000)
    }
    sendKey(115)
    usleep(300_000)
}

func scrollListDown() {
    let fallback = CGPoint(x: 560, y: 720)
    let point: CGPoint
    if let window = try? focusedWindow(),
       let table = findElement(window, { role($0) == "AXTable" }),
       let tablePoint = cgPoint(table),
       let tableSize = cgSize(table) {
        point = CGPoint(x: tablePoint.x + tableSize.width * 0.5, y: tablePoint.y + tableSize.height * 0.82)
        AXUIElementPerformAction(table, "AXScrollDown" as CFString)
    } else {
        point = fallback
    }
    moveMouse(point)
    usleep(100_000)
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: -12, wheel2: 0, wheel3: 0)?
        .post(tap: .cghidEventTap)
    usleep(100_000)
    CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: -760, wheel2: 0, wheel3: 0)?
        .post(tap: .cghidEventTap)
    usleep(700_000)
}

func scrapeVisible(row: ScheduleRow, date: String) -> CsvRow? {
    guard let point = rowHoverPoint(row) else { return nil }
    guard isLikelyVisible(point) else { return nil }
    moveMouse(CGPoint(x: 720, y: 840))
    usleep(200_000)
    moveMouse(point)
    usleep(700_000)
    guard let window = try? focusedWindow() else { return nil }
    let texts = flattenTexts(window)
    let start = cleanTime(field(texts, "시작:"))
    let end = cleanTime(field(texts, "종료:"))
    let type = field(texts, "유형:")
    guard !start.isEmpty, !end.isEmpty, !type.isEmpty else { return nil }
    let fallback = parseFallback(row.detail)
    let customer = stripParen(field(texts, "고객:"))
    let staff = stripParen(field(texts, "인력:"))
    return CsvRow(
        date: date,
        start: padTime(start),
        end: padTime(end),
        customer: customer.isEmpty ? fallback.customer : customer,
        staff: staff.isEmpty ? fallback.staff : staff,
        type: type,
        memo: fallback.memo
    )
}

func writeCsv(rows: [CsvRow], to path: String) throws {
    var merged: [String: CsvRow] = [:]
    for row in readExistingCsvRows(from: path) + rows {
        let key = [row.date, row.start, row.end, row.customer, row.staff, row.type, row.memo].joined(separator: "\t")
        merged[key] = row
    }
    let outputRows = merged.values.sorted {
        if $0.date != $1.date { return $0.date < $1.date }
        if $0.start != $1.start { return $0.start < $1.start }
        if $0.customer != $1.customer { return $0.customer < $1.customer }
        return $0.staff < $1.staff
    }
    let header = ["날짜", "시작시간", "종료시간", "고객", "담당인력", "유형", "메모"].joined(separator: ",")
    let lines = [header] + outputRows.map {
        [$0.date, $0.start, $0.end, $0.customer, $0.staff, $0.type, $0.memo]
            .map(csvEscape)
            .joined(separator: ",")
    }
    try (lines.joined(separator: "\n") + "\n")
        .write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
}

func isoDate(year: Int, month: Int, day: Int) -> String {
    String(format: "%04d-%02d-%02d", year, month, day)
}

func scrapeDay(year: Int, month: Int, day: Int, outputPath: String? = nil) throws -> (Int, Int) {
    let heading = "\(year)년 \(month)월 \(day)일"
    let date = isoDate(year: year, month: month, day: day)
    try ensureDay(heading)
    usleep(300_000)
    resetScrollPositions()

    let all = try scheduleRows()
    var captured: [String: CsvRow] = [:]
    var lastMissingCount = Int.max
    var stalePasses = 0

    for _ in 0..<8 {
        let visible = try scheduleRows()
        for row in visible {
            let key = "\(row.time)\t\(row.detail)"
            guard captured[key] == nil else { continue }
            if let csvRow = scrapeVisible(row: row, date: date) {
                captured[key] = csvRow
            }
        }

        let missingCount = all.filter { captured["\($0.time)\t\($0.detail)"] == nil }.count
        if missingCount == 0 { break }
        stalePasses = missingCount == lastMissingCount ? stalePasses + 1 : 0
        if stalePasses >= 2 { break }
        lastMissingCount = missingCount
        scrollListDown()
    }

    let rows = all.compactMap { captured["\($0.time)\t\($0.detail)"] }
    try writeCsv(rows: rows, to: outputPath ?? "output/\(date).csv")
    print("\(date): \(rows.count)/\(all.count)")
    return (rows.count, all.count)
}

func main() throws {
    guard AXIsProcessTrusted() else {
        fputs("Accessibility access is required.\n", stderr)
        exit(1)
    }

    let args = Array(CommandLine.arguments.dropFirst()).compactMap { Int($0) }
    let year = args.count > 0 ? args[0] : 2026
    let month = args.count > 1 ? args[1] : 3
    let startDay = args.count > 2 ? args[2] : 7
    let endDay = args.count > 3 ? args[3] : startDay

    try ensureDayList()
    var failures: [String] = []
    guard startDay <= endDay else {
        throw NSError(domain: "scrape", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid day range \(startDay)-\(endDay)"])
    }

    for day in stride(from: startDay, through: endDay, by: 1) {
        let outputPath = startDay == endDay
            ? String(format: "output/%04d_%02d_%02d_hover.csv", year, month, day)
            : String(format: "output/%04d_%02d_hover.csv", year, month)
        let (captured, total) = try scrapeDay(year: year, month: month, day: day, outputPath: outputPath)
        if captured != total {
            failures.append(String(format: "%04d-%02d-%02d %d/%d", year, month, day, captured, total))
        }
        if day < endDay {
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
    fputs("Range scrape failed: \(error)\n", stderr)
    exit(1)
}
