import ApplicationServices
import AppKit
import Foundation

struct DetailRow: Codable {
    let listTime: String
    let listDetail: String
    let customer: String
    let staff: String
    let type: String
    let date: String
    let startTime: String
    let endTime: String
    let memo: String
}

enum DetailError: Error {
    case appNotFound
    case focusedWindowNotFound
    case buttonNotFound(String)
    case headingNotFound
    case rowOpenFailed(String)
    case modalNotFound
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

func firstApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "ai.perplexity.comet").first
}

func focusedWindow() throws -> AXUIElement {
    guard let app = firstApp() else { throw DetailError.appNotFound }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let window: AXUIElement = attr(axApp, kAXFocusedWindowAttribute as String) else {
        throw DetailError.focusedWindowNotFound
    }
    return window
}

func findElement(_ element: AXUIElement, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if predicate(element) { return element }
    for child in children(element) {
        if let found = findElement(child, where: predicate) { return found }
    }
    return nil
}

func findAll(_ element: AXUIElement, where predicate: (AXUIElement) -> Bool, into result: inout [AXUIElement]) {
    if predicate(element) { result.append(element) }
    for child in children(element) {
        findAll(child, where: predicate, into: &result)
    }
}

func button(named name: String) throws -> AXUIElement {
    let window = try focusedWindow()
    if let found = findElement(window, where: { role($0) == "AXButton" && title($0) == name }) {
        return found
    }
    throw DetailError.buttonNotFound(name)
}

func pressButton(named name: String) throws {
    let target = try button(named: name)
    let err = AXUIElementPerformAction(target, kAXPressAction as CFString)
    guard err == .success else { throw DetailError.buttonNotFound(name) }
}

func headingText() throws -> String {
    let window = try focusedWindow()
    if let heading = findElement(window, where: {
        let text = title($0)
        return role($0) == "AXHeading"
            && text.contains("2026년")
            && text.contains("월")
            && (text == "2026년 3월" || text.contains("일"))
    }) {
        return title(heading)
    }
    throw DetailError.headingNotFound
}

func waitForHeadingChange(from previous: String, timeoutSeconds: TimeInterval = 3.0) throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        usleep(120_000)
        if let current = try? headingText(), current != previous {
            return
        }
    }
    throw DetailError.headingNotFound
}

func ensureDayList(at targetHeading: String) throws {
    var heading = try headingText()
    if !heading.contains("일") || heading == "2026년 4월" {
        try pressButton(named: "일 리스트")
        usleep(300_000)
        heading = try headingText()
    }

    while heading != targetHeading {
        let currentDay = Int(heading.components(separatedBy: " ").last?.replacingOccurrences(of: "일", with: "") ?? "") ?? 0
        let targetDay = Int(targetHeading.components(separatedBy: " ").last?.replacingOccurrences(of: "일", with: "") ?? "") ?? 0
        let buttonName = currentDay > targetDay ? "‹" : "›"
        try pressButton(named: buttonName)
        try waitForHeadingChange(from: heading)
        heading = try headingText()
    }
}

func flattenTexts(_ element: AXUIElement) -> [String] {
    var texts: [String] = []
    let currentRole = role(element)
    if ["AXStaticText", "AXTextField", "AXButton", "AXLink", "AXHeading"].contains(currentRole) {
        let t = title(element)
        let v = value(element)
        if !t.isEmpty {
            texts.append(t)
        } else if !v.isEmpty {
            texts.append(v)
        }
    }
    for child in children(element) {
        texts.append(contentsOf: flattenTexts(child))
    }
    return texts
}

func scheduleRows() throws -> [(element: AXUIElement, time: String, detail: String)] {
    let window = try focusedWindow()
    var rows: [AXUIElement] = []
    findAll(window, where: { role($0) == "AXRow" }, into: &rows)

    return rows.compactMap { row in
        let texts = flattenTexts(row).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard texts.count >= 2 else { return nil }
        let first = texts[0]
        guard first.first?.isNumber == true else { return nil }
        return (row, first, texts[1])
    }
}

func modalValue(afterLabel label: String) throws -> String {
    let window = try focusedWindow()
    guard let labelElement = findElement(window, where: { role($0) == "AXStaticText" && title($0) == label }) else {
        return ""
    }
    if let container = findElement(window, where: { child in
        children(child).contains { $0 as AnyObject === labelElement as AnyObject }
    }) {
        let siblings = children(container)
        if let idx = siblings.firstIndex(where: { $0 as AnyObject === labelElement as AnyObject }) {
            for sibling in siblings.suffix(from: idx + 1) {
                let texts = flattenTexts(sibling).filter { !$0.isEmpty && $0 != label }
                if let first = texts.first {
                    return first
                }
            }
        }
    }

    guard let modal = findElement(window, where: { role($0) == "AXButton" && title($0) == "취소" }) else {
        throw DetailError.modalNotFound
    }
    let root = modal
    let texts = flattenTexts(root)
    if let idx = texts.firstIndex(of: label), idx + 1 < texts.count {
        return texts[idx + 1]
    }
    return ""
}

func currentModalRow(listTime: String, listDetail: String) throws -> DetailRow {
    let window = try focusedWindow()
    guard findElement(window, where: { role($0) == "AXButton" && title($0) == "취소" }) != nil else {
        throw DetailError.modalNotFound
    }

    let customer = modalValueDirect(label: "고객", fallbackButtonIndex: 0)
    let staff = modalValueDirect(label: "담당 인력", fallbackButtonIndex: 1)
    let type = modalValueDirect(label: "유형", fallbackButtonIndex: 2)
    let date = modalTextFieldValue(label: "날짜")
    let startTime = modalTextFieldValue(label: "시작시간")
    let endTime = modalTextFieldValue(label: "종료시간")
    let memo = modalTextFieldValue(label: "메모")

    return DetailRow(
        listTime: listTime,
        listDetail: listDetail,
        customer: customer,
        staff: staff,
        type: type,
        date: date,
        startTime: startTime,
        endTime: endTime,
        memo: memo
    )
}

func modalTextFieldValue(label: String) -> String {
    guard let window = try? focusedWindow(),
          let textField = findElement(window, where: { role($0) == "AXTextField" && title($0) == label }) else {
        return ""
    }
    return value(textField)
}

func modalValueDirect(label: String, fallbackButtonIndex: Int) -> String {
    guard let window = try? focusedWindow() else { return "" }
    if let staticLabel = findElement(window, where: { role($0) == "AXStaticText" && title($0) == label }) {
        let siblings = children(findParent(of: staticLabel, in: window) ?? window)
        if let idx = siblings.firstIndex(where: { $0 as AnyObject === staticLabel as AnyObject }) {
            for sibling in siblings.suffix(from: idx + 1) {
                if role(sibling) == "AXPopUpButton" {
                    return title(sibling).isEmpty ? value(sibling) : title(sibling)
                }
                let nestedButtons = nestedElements(in: sibling, roleName: "AXPopUpButton")
                if let first = nestedButtons.first {
                    return title(first).isEmpty ? value(first) : title(first)
                }
            }
        }
    }
    let popups = nestedElements(in: window, roleName: "AXPopUpButton")
    guard fallbackButtonIndex < popups.count else { return "" }
    let popup = popups[fallbackButtonIndex]
    return title(popup).isEmpty ? value(popup) : title(popup)
}

func nestedElements(in root: AXUIElement, roleName: String) -> [AXUIElement] {
    var result: [AXUIElement] = []
    findAll(root, where: { role($0) == roleName }, into: &result)
    return result
}

func findParent(of target: AXUIElement, in root: AXUIElement) -> AXUIElement? {
    for child in children(root) {
        if child as AnyObject === target as AnyObject {
            return root
        }
        if let found = findParent(of: target, in: child) {
            return found
        }
    }
    return nil
}

func openRow(_ row: AXUIElement, expectedDetail: String) throws {
    for target in [row] + children(row) {
        let err = AXUIElementPerformAction(target, kAXPressAction as CFString)
        if err == .success {
            usleep(300_000)
            if let window = try? focusedWindow(),
               findElement(window, where: { role($0) == "AXButton" && title($0) == "취소" }) != nil {
                return
            }
        }
    }
    throw DetailError.rowOpenFailed(expectedDetail)
}

func closeModal() throws {
    try pressButton(named: "취소")
    usleep(250_000)
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    let targetHeading = args.first ?? "2026년 3월 4일"
    let outputPath = args.dropFirst().first ?? "./output/day_details.json"

    guard AXIsProcessTrusted() else {
        fputs("Accessibility access is required.\n", stderr)
        exit(1)
    }

    try ensureDayList(at: targetHeading)
    let rows = try scheduleRows()
    var details: [DetailRow] = []
    for row in rows {
        try openRow(row.element, expectedDetail: row.detail)
        let detail = try currentModalRow(listTime: row.time, listDetail: row.detail)
        details.append(detail)
        try closeModal()
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(details)
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: outputURL)
    print(outputURL.path)
}

do {
    try main()
} catch {
    fputs("Detail scrape failed: \(error)\n", stderr)
    exit(1)
}
