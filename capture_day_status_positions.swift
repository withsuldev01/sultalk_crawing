import ApplicationServices
import AppKit
import Foundation

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

func elementText(_ element: AXUIElement) -> String {
    let t = title(element)
    if !t.isEmpty { return t }
    return value(element)
}

func focusedWindow() throws -> AXUIElement {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.perplexity.comet").first else {
        throw NSError(domain: "status", code: 1, userInfo: [NSLocalizedDescriptionKey: "Comet not running"])
    }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let window: AXUIElement = attr(axApp, kAXFocusedWindowAttribute as String) else {
        throw NSError(domain: "status", code: 2, userInfo: [NSLocalizedDescriptionKey: "No focused Comet window"])
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

func flattenTexts(_ root: AXUIElement) -> [String] {
    var out: [String] = []
    if ["AXStaticText", "AXTextField", "AXButton", "AXLink", "AXHeading"].contains(role(root)) {
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
        throw NSError(domain: "status", code: 3, userInfo: [NSLocalizedDescriptionKey: "Button not found: \(name)"])
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
    if headingText().contains("일") { return }
    try pressButton("일 리스트")
}

func dateParts(_ heading: String) -> (year: Int, month: Int, day: Int)? {
    guard let match = heading.range(of: #"(\d{4})년\s+(\d{1,2})월\s+(\d{1,2})일"#, options: .regularExpression) else {
        return nil
    }
    let numbers = String(heading[match])
        .replacingOccurrences(of: "년", with: "")
        .replacingOccurrences(of: "월", with: "")
        .replacingOccurrences(of: "일", with: "")
        .split(separator: " ")
        .compactMap { Int($0) }
    guard numbers.count == 3 else { return nil }
    return (numbers[0], numbers[1], numbers[2])
}

func compareDateHeading(_ lhs: String, _ rhs: String) -> Int {
    guard let left = dateParts(lhs), let right = dateParts(rhs) else { return 0 }
    if left.year != right.year { return left.year - right.year }
    if left.month != right.month { return left.month - right.month }
    return left.day - right.day
}

func ensureDay(_ targetHeading: String) throws {
    try ensureDayList()
    while headingText() != targetHeading {
        let current = headingText()
        guard !current.isEmpty else {
            throw NSError(domain: "status", code: 4, userInfo: [NSLocalizedDescriptionKey: "Date heading not found"])
        }
        let direction = compareDateHeading(current, targetHeading) > 0 ? "‹" : "›"
        try pressButton(direction)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline && headingText() == current {
            usleep(100_000)
        }
    }
}

func moveMouse(_ point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func sendKey(_ keyCode: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    usleep(150_000)
}

func resetScrollPositions() {
    sendKey(115)
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
    let point: CGPoint
    if let window = try? focusedWindow(),
       let table = findElement(window, { role($0) == "AXTable" }),
       let tablePoint = cgPoint(table),
       let tableSize = cgSize(table) {
        point = CGPoint(x: tablePoint.x + tableSize.width * 0.5, y: tablePoint.y + tableSize.height * 0.82)
        AXUIElementPerformAction(table, "AXScrollDown" as CFString)
    } else {
        point = CGPoint(x: 560, y: 720)
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

func schedulePayloads(pass: Int, screenshot: String) throws -> [[String: Any]] {
    let window = try focusedWindow()
    var rows: [AXUIElement] = []
    findAll(window, { role($0) == "AXRow" }, into: &rows)
    return rows.compactMap { row in
        let texts = flattenTexts(row).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard texts.count >= 2, texts[0].first?.isNumber == true else { return nil }
        let cells = children(row).filter { role($0) == "AXCell" }
        guard cells.count >= 2,
              let timePoint = cgPoint(cells[0]), let timeSize = cgSize(cells[0]),
              let detailPoint = cgPoint(cells[1]), let detailSize = cgSize(cells[1]) else { return nil }
        return [
            "pass": pass,
            "screenshot": screenshot,
            "time": texts[0],
            "detail": texts[1],
            "timeX": timePoint.x,
            "timeY": timePoint.y,
            "timeW": timeSize.width,
            "timeH": timeSize.height,
            "detailX": detailPoint.x,
            "detailY": detailPoint.y,
            "detailW": detailSize.width,
            "detailH": detailSize.height
        ]
    }
}

func captureScreenshot(path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", path]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw NSError(domain: "status", code: 5, userInfo: [NSLocalizedDescriptionKey: "screencapture failed"])
    }
}

func main() throws {
    guard AXIsProcessTrusted() else {
        fputs("Accessibility access is required.\n", stderr)
        exit(1)
    }
    let args = CommandLine.arguments
    guard args.count >= 5,
          let year = Int(args[1]),
          let month = Int(args[2]),
          let day = Int(args[3]) else {
        fputs("Usage: swift capture_day_status_positions.swift YEAR MONTH DAY OUTPUT_DIR\n", stderr)
        exit(1)
    }
    let outputDir = args[4]
    try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    try ensureDay("\(year)년 \(month)월 \(day)일")
    resetScrollPositions()

    var payloads: [[String: Any]] = []
    var seenKeys = Set<String>()
    var stalePasses = 0
    for pass in 0..<6 {
        let screenshot = String(format: "%@/%04d_%02d_%02d_pass%d.png", outputDir, year, month, day, pass)
        moveMouse(CGPoint(x: 40, y: 40))
        usleep(150_000)
        try captureScreenshot(path: screenshot)
        let rows = try schedulePayloads(pass: pass, screenshot: screenshot)
        var newCount = 0
        for row in rows {
            let key = "\(row["time"] ?? "")\t\(row["detail"] ?? "")"
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                newCount += 1
            }
        }
        payloads.append(contentsOf: rows)
        if pass > 0 && newCount == 0 {
            stalePasses += 1
            if stalePasses >= 2 { break }
        } else {
            stalePasses = 0
        }
        scrollListDown()
    }

    let jsonPath = String(format: "%@/%04d_%02d_%02d_rows.json", outputDir, year, month, day)
    let data = try JSONSerialization.data(withJSONObject: payloads, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: jsonPath))
    print(String(format: "%04d-%02d-%02d: %d row-position samples, %d unique rows", year, month, day, payloads.count, seenKeys.count))
}

do {
    try main()
} catch {
    fputs("Status capture failed: \(error)\n", stderr)
    exit(1)
}
