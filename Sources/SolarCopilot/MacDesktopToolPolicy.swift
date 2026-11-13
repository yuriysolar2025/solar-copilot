import Foundation
import CoreGraphics

enum MacDesktopToolPolicy {
    enum PolicyError: LocalizedError {
        case invalidArguments(String)
        case blocked(String)

        var errorDescription: String? {
            switch self {
            case .invalidArguments(let message), .blocked(let message): return message
            }
        }
    }

    static let safeKeys: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "page_up": 116, "page_down": 121
    ]

    static func coordinate(_ value: Any?, name: String) throws -> CGFloat {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw PolicyError.invalidArguments("Координата \(name) должна быть числом.")
        }
        let result = CGFloat(number.doubleValue)
        guard result.isFinite else {
            throw PolicyError.invalidArguments("Координата \(name) должна быть конечным числом.")
        }
        return result
    }

    static func validatedURL(_ raw: Any?) throws -> URL {
        guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 2048,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty else {
            throw PolicyError.invalidArguments("Разрешены только полные http/https URL длиной до 2048 символов.")
        }
        guard components.user == nil, components.password == nil else {
            throw PolicyError.blocked("URL со встроенным логином или паролем заблокирован.")
        }
        let sensitive = ["token", "secret", "password", "passwd", "api_key", "apikey", "access_key"]
        if components.queryItems?.contains(where: { item in
            sensitive.contains(where: { item.name.lowercased().contains($0) })
        }) == true {
            throw PolicyError.blocked("URL с секретом в параметрах заблокирован.")
        }
        guard let url = components.url else {
            throw PolicyError.invalidArguments("Не удалось разобрать URL.")
        }
        return url
    }

    static func validatedBundleID(_ raw: Any?) throws -> String {
        guard let value = raw as? String, value.count <= 160,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
            throw PolicyError.invalidArguments("Передай корректный bundle_id приложения.")
        }
        return value
    }

    static func validatedKey(_ raw: Any?) throws -> CGKeyCode {
        guard let key = (raw as? String)?.lowercased(), let code = safeKeys[key] else {
            throw PolicyError.blocked("Эта клавиша не разрешена. Доступны: \(safeKeys.keys.sorted().joined(separator: ", ")).")
        }
        return code
    }

    static func validatedScroll(_ raw: Any?, name: String) throws -> Int32 {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw PolicyError.invalidArguments("Прокрутка \(name) должна быть целым числом.")
        }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value, abs(value) <= 120 else {
            throw PolicyError.blocked("Прокрутка за один вызов должна быть целым числом от -120 до 120.")
        }
        return Int32(value)
    }

    static func validatedClickCount(_ raw: Any?) throws -> Int64 {
        if raw == nil { return 1 }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue else {
            throw PolicyError.invalidArguments("click_count должен быть числом 1 или 2.")
        }
        let value = number.int64Value
        guard value == 1 || value == 2 else {
            throw PolicyError.blocked("Разрешён одинарный или двойной клик.")
        }
        return value
    }

    static func validatedIntent(_ raw: Any?) throws -> String {
        guard let value = raw as? String else {
            throw PolicyError.invalidArguments("Перед действием укажи краткий intent: что именно будет нажато.")
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized.count <= 240 else {
            throw PolicyError.invalidArguments("intent должен содержать от 1 до 240 символов.")
        }
        let blocked = [
            "отправ", "send", "опубли", "publish", "удал", "delete", "remove",
            "оплат", "pay", "покуп", "buy", "перевод денег", "transfer money",
            "парол", "password", "credential", "api key", "секрет", "secret",
            "выдать доступ", "grant access", "разрешение", "permission",
            "подтверд", "confirm", "соглас", "agree", "accept", "submit", "отправить форму",
            "checkout", "оформить заказ", "заказ оформ", "войти", "login", "log in", "sign in"
        ]
        if let match = blocked.first(where: normalized.contains) {
            throw PolicyError.blocked("Действие с intent «\(match)» требует отдельного подтверждения в Codex.")
        }
        return normalized
    }

    static func selfTest() -> [String] {
        var failures: [String] = []
        if (try? validatedURL("https://example.com/path?q=1")) == nil { failures.append("safe URL rejected") }
        if (try? validatedURL("javascript:alert(1)")) != nil { failures.append("javascript URL accepted") }
        if (try? validatedURL("https://u:p@example.com")) != nil { failures.append("credential URL accepted") }
        if (try? validatedURL("https://example.com?access_token=x")) != nil { failures.append("secret query accepted") }
        if (try? validatedKey("escape")) == nil { failures.append("safe key rejected") }
        if (try? validatedKey("q")) != nil { failures.append("arbitrary key accepted") }
        if (try? validatedScroll(121, name: "vertical")) != nil { failures.append("large scroll accepted") }
        if (try? validatedClickCount(true)) != nil { failures.append("boolean click count accepted") }
        if (try? validatedIntent("отправить сообщение")) != nil { failures.append("external action intent accepted") }
        if (try? validatedIntent("подтвердить вход")) != nil { failures.append("confirmation intent accepted") }
        if (try? validatedIntent("submit form")) != nil { failures.append("submit intent accepted") }
        if (try? validatedIntent("checkout order")) != nil { failures.append("checkout intent accepted") }
        if (try? validatedIntent("login to account")) != nil { failures.append("login intent accepted") }
        if (try? validatedIntent("открыть карточку лида")) == nil { failures.append("safe intent rejected") }
        if (try? validatedBundleID("com.apple.Safari")) == nil { failures.append("bundle id rejected") }
        if (try? validatedBundleID("../../bad")) != nil { failures.append("invalid bundle id accepted") }
        return failures
    }
}
