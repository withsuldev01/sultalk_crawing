import ApplicationServices
import AppKit
import Foundation

struct DaySchedule: Codable {
    let date: String
    let weekday: String
    let rows: [ScheduleRow]
}

struct ScheduleRow: Codable {
    let time: String
    let detail: String
}

enum ScrapeError: Error {
    case appNotFound
    case focusedWindowNotFound
    case buttonNotFound(String)
    case dateHeadingNotFound
    case navigationTimeout(String)
    case outputEncodingFailed
}

func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    if err == .success {
        return value as? T
    }
    return nil
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

func firstApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "ai.perplexity.comet").first
}

func focusedWindow() throws -> AXUIElement {
    guard let app = firstApp() else {
        throw ScrapeError.appNotFound
    }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let window: AXUIElement = attr(axApp, kAXFocusedWindowAttribute as String) else {
        throw ScrapeError.focusedWindowNotFound
    }
    return window
}

func findElement(_ element: AXUIElement, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if predicate(element) {
        return element
    }
    for child in children(element) {
        if let found = findElement(child, where: predicate) {
            return found
        }
    }
    return nil
}

func button(named name: String) throws -> AXUIElement {
    let window = try focusedWindow()
    if let found = findElement(window, where: { role($0) == "AXButton" && title($0) == name }) {
        return found
    }
    throw ScrapeError.buttonNotFound(name)
}

func pressButton(named name: String) throws {
    let button = try button(named: name)
    let err = AXUIElementPerformAction(button, kAXPressAction as CFString)
    if err != .success {
        throw ScrapeError.buttonNotFound(name)
    }
}

func allRows(in element: AXUIElement) -> [[String]] {
    var result: [[String]] = []
    func collect(_ current: AXUIElement) {
        if role(current) == "AXRow" {
            let texts = flattenTexts(current)
            if !texts.isEmpty {
                result.append(texts)
            }
        }
        for child in children(current) {
            collect(child)
        }
    }
    collect(element)
    return result
}

func flattenTexts(_ element: AXUIElement) -> [String] {
    let currentRole = role(element)
    var texts: [String] = []
    if ["AXStaticText", "AXTextField", "AXButton", "AXLink", "AXHeading"].contains(currentRole) {
        let currentTitle = title(element)
        let currentValue = value(element)
        if !currentTitle.isEmpty {
            texts.append(currentTitle)
        } else if !currentValue.isEmpty {
            texts.append(currentValue)
        }
    }
    for child in children(element) {
        texts.append(contentsOf: flattenTexts(child))
    }
    return texts
}

func currentDateHeading() throws -> String {
    let window = try focusedWindow()
    if let heading = findElement(window, where: {
        role($0) == "AXHeading" && title($0).contains("년") && title($0).contains("월")
    }) {
        return title(heading)
    }
    throw ScrapeError.dateHeadingNotFound
}

func dayNumber(from heading: String) -> Int {
    let match = heading.range(of: #"(\d+)일"#, options: .regularExpression)
    let number = match.map { String(heading[$0]).replacingOccurrences(of: "일", with: "") } ?? ""
    return Int(number) ?? 0
}

func currentDaySchedule() throws -> DaySchedule {
    let window = try focusedWindow()
    let heading = try currentDateHeading()
    let rows = allRows(in: window)
    guard let weekday = rows.first?.first else {
        return DaySchedule(date: heading, weekday: "", rows: [])
    }

    let scheduleRows = rows.compactMap { row -> ScheduleRow? in
        guard row.count >= 2 else { return nil }
        let first = row[0]
        guard first.first?.isNumber == true else { return nil }
        return ScheduleRow(time: first, detail: row[1])
    }

    return DaySchedule(date: heading, weekday: weekday, rows: scheduleRows)
}

func waitForHeadingChange(from previous: String, timeoutSeconds: TimeInterval = 8.0) throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        usleep(120_000)
        if let current = try? currentDateHeading(), current != previous {
            return
        }
    }
    throw ScrapeError.navigationTimeout(previous)
}

func ensureListView() throws {
    let heading = try currentDateHeading()
    if heading.contains("일") && heading != "2026년 4월" {
        return
    }
    try pressButton(named: "일 리스트")
    usleep(300_000)
}

func navigateToFirstDay(targetHeading: String) throws {
    var current = try currentDateHeading()
    while current != targetHeading {
        let buttonName = dayNumber(from: current) > dayNumber(from: targetHeading) ? "‹" : "›"
        try pressButton(named: buttonName)
        try waitForHeadingChange(from: current)
        current = try currentDateHeading()
    }
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    let year = Int(args.first ?? "2026") ?? 2026
    let month = Int(args.dropFirst().first ?? "4") ?? 4
    let outputPath = args.dropFirst(2).first ?? "./output/\(year)_\(String(format: "%02d", month))_schedule_raw.json"
    let calendar = Calendar(identifier: .gregorian)
    let comps = DateComponents(year: year, month: month)
    guard let firstDate = calendar.date(from: comps),
          let range = calendar.range(of: .day, in: .month, for: firstDate) else {
        throw ScrapeError.outputEncodingFailed
    }
    let dayCount = range.count
    let firstHeading = "\(year)년 \(month)월 1일"

    guard AXIsProcessTrusted() else {
        fputs("Accessibility access is required.\n", stderr)
        exit(1)
    }

    try ensureListView()
    try navigateToFirstDay(targetHeading: firstHeading)

    var days: [DaySchedule] = []
    for day in 1...dayCount {
        let current = try currentDaySchedule()
        days.append(current)

        if day < dayCount {
            let heading = current.date
            try pressButton(named: "›")
            try waitForHeadingChange(from: heading)
        }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(days)

    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: outputURL)
    print(outputURL.path)
}

do {
    try main()
} catch {
    fputs("Scrape failed: \(error)\n", stderr)
    exit(1)
}
