import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class MacDesktopToolRuntime {
    private var lastScreenInspectionAt: Date?
    private let inspectionTTL: TimeInterval = 20

    func recordScreenInspection() {
        lastScreenInspectionAt = Date()
    }

    func preflight() -> String {
        let screen = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        return "Запись экрана: \(screen ? "PASS" : "FAIL"); Универсальный доступ: \(accessibility ? "PASS" : "FAIL")."
    }

    func selfTest() -> String {
        let failures = MacDesktopToolPolicy.selfTest()
        return failures.isEmpty ? "PASS: policy self-test, побочных UI-действий не выполнено." : "FAIL: \(failures.joined(separator: "; "))"
    }

    func moveCursor(arguments: [String: Any]) -> String {
        do {
            try requireAccessibility()
            let point = try validatedPoint(arguments)
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                      mouseCursorPosition: point, mouseButton: .left) else {
                return "Не удалось создать событие перемещения курсора."
            }
            event.post(tap: .cghidEventTap)
            return "Курсор перемещён в \(Int(point.x)), \(Int(point.y))."
        } catch { return failure(error) }
    }

    func click(arguments: [String: Any]) -> String {
        do {
            try requireAccessibility()
            try requireRecentInspection()
            _ = try MacDesktopToolPolicy.validatedIntent(arguments["intent"])
            let point = try validatedPoint(arguments)
            let buttonName = (arguments["button"] as? String)?.lowercased() ?? "left"
            let button: CGMouseButton
            let downType: CGEventType
            let upType: CGEventType
            switch buttonName {
            case "left": (button, downType, upType) = (.left, .leftMouseDown, .leftMouseUp)
            case "right": (button, downType, upType) = (.right, .rightMouseDown, .rightMouseUp)
            default: throw MacDesktopToolPolicy.PolicyError.blocked("Разрешены только left и right click.")
            }
            let count = try MacDesktopToolPolicy.validatedClickCount(arguments["click_count"])
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                                     mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                                   mouseCursorPosition: point, mouseButton: button) else {
                return "Не удалось создать событие клика."
            }
            down.setIntegerValueField(.mouseEventClickState, value: count)
            up.setIntegerValueField(.mouseEventClickState, value: count)
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            return "Выполнен \(buttonName) click в \(Int(point.x)), \(Int(point.y))."
        } catch { return failure(error) }
    }

    func scroll(arguments: [String: Any]) -> String {
        do {
            try requireAccessibility()
            try requireRecentInspection()
            let vertical = try MacDesktopToolPolicy.validatedScroll(arguments["vertical"] ?? 0, name: "vertical")
            let horizontal = try MacDesktopToolPolicy.validatedScroll(arguments["horizontal"] ?? 0, name: "horizontal")
            guard vertical != 0 || horizontal != 0 else {
                throw MacDesktopToolPolicy.PolicyError.invalidArguments("Укажи ненулевую прокрутку.")
            }
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                      wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else {
                return "Не удалось создать событие прокрутки."
            }
            event.post(tap: .cghidEventTap)
            return "Прокрутка выполнена."
        } catch { return failure(error) }
    }

    func pressKey(arguments: [String: Any]) -> String {
        do {
            try requireAccessibility()
            try requireRecentInspection()
            _ = try MacDesktopToolPolicy.validatedIntent(arguments["intent"])
            let code = try MacDesktopToolPolicy.validatedKey(arguments["key"])
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
                return "Не удалось создать событие клавиши."
            }
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            return "Клавиша нажата."
        } catch { return failure(error) }
    }

    func openURL(arguments: [String: Any]) -> String {
        do {
            let url = try MacDesktopToolPolicy.validatedURL(arguments["url"])
            return NSWorkspace.shared.open(url) ? "URL открыт: \(url.host ?? "сайт")." : "macOS не смогла открыть URL."
        } catch { return failure(error) }
    }

    func openApplication(arguments: [String: Any]) -> String {
        do {
            let bundleID = try MacDesktopToolPolicy.validatedBundleID(arguments["bundle_id"])
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return "Приложение с bundle_id \(bundleID) не найдено."
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error { AudioRecorder.log("desktop: open app failed: \(error.localizedDescription)") }
            }
            return "Открываю приложение \(bundleID)."
        } catch { return failure(error) }
    }

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw MacDesktopToolPolicy.PolicyError.blocked(
                "Нет Универсального доступа. Разреши Solar Copilot в Системные настройки → Конфиденциальность и безопасность → Универсальный доступ.")
        }
    }

    private func requireRecentInspection() throws {
        guard let date = lastScreenInspectionAt, Date().timeIntervalSince(date) <= inspectionTTL else {
            throw MacDesktopToolPolicy.PolicyError.blocked("Сначала вызови inspect_screen, затем повтори действие в течение 20 секунд.")
        }
    }

    private func validatedPoint(_ arguments: [String: Any]) throws -> CGPoint {
        let point = CGPoint(x: try MacDesktopToolPolicy.coordinate(arguments["x"], name: "x"),
                            y: try MacDesktopToolPolicy.coordinate(arguments["y"], name: "y"))
        guard activeDisplayBounds().contains(where: { $0.contains(point) }) else {
            throw MacDesktopToolPolicy.PolicyError.blocked("Координаты находятся вне активных дисплеев.")
        }
        return point
    }

    private func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }

    private func failure(_ error: Error) -> String {
        "Действие заблокировано: \(error.localizedDescription)"
    }
}
