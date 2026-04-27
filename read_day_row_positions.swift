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
        throw NSError(domain: "rows", code: 1, userInfo: [NSLocalizedDescriptionKey: "Comet not running"])
    }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let window: AXUIElement = attr(axApp, kAXFocusedWindowAttribute as String) else {
        throw NSError(domain: "rows", code: 2, userInfo: [NSLocalizedDescriptionKey: "No focused Comet window"])
    }
    return window
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

let window = try focusedWindow()
var rows: [AXUIElement] = []
findAll(window, { role($0) == "AXRow" }, into: &rows)

print("[")
var first = true
for row in rows {
    let texts = flattenTexts(row).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard texts.count >= 2, texts[0].first?.isNumber == true else { continue }
    let cells = children(row).filter { role($0) == "AXCell" }
    guard cells.count >= 2,
          let timePoint = cgPoint(cells[0]), let timeSize = cgSize(cells[0]),
          let detailPoint = cgPoint(cells[1]), let detailSize = cgSize(cells[1]) else { continue }
    let payload: [String: Any] = [
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
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    if !first { print(",") }
    first = false
    print(String(data: data, encoding: .utf8)!, terminator: "")
}
print("\n]")
