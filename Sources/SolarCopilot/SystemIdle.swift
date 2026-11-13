import AppKit
import CoreGraphics

/// Локальные (без сети) сигналы «Юрия нет за машиной» — чтобы фоновые vision-петли
/// (компаньон-болтовня, наблюдатель) НЕ жгли Claude по заблокированному/спящему экрану
/// ночью и в простое. Всё считается мгновенно из системных API, ноль LLM-вызовов.
enum SystemIdle {
    /// Секунды с последнего ввода мышью/клавиатурой.
    static func secondsSinceInput() -> Double {
        let anyEvent = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType — любой ввод
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    /// Главный дисплей спит (ночь / энергосбережение).
    static func displayAsleep() -> Bool {
        return CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Экран заблокирован.
    static func screenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// «За маком никого»: залочено, дисплей спит, или ввода нет дольше backstop.
    /// Дисплей-сон ловит ночь, не наказывая просмотр кино (там экран активен).
    /// idleBackstop — страховка на «оставил включённым и ушёл» (дефолт 30 мин).
    static func awayFromMac(idleBackstop: Double = 1800) -> Bool {
        return screenLocked() || displayAsleep() || secondsSinceInput() > idleBackstop
    }
}
