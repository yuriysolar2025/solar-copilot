import Foundation

enum CallMode { case drive, listen }

/// «Мозг» копилота: периодические подсказки (drive-mode) / заметки (listen-mode)
/// по ходу разговора + авто-детект режима + финальная сводка на «Стоп».
/// Промпты портированы из `copilot/daemon.py` — единый источник стиля.
/// LLM-вызов спрятан за `LLMProvider`; персона/чек-лист читаются из `resourcesDir`.
@MainActor
final class CopilotBrain {
    private let llm: LLMProvider
    private let cfg: AppConfig
    private var resourcesDir: URL { cfg.copilotResourcesDir }

    // Состояние сессии (всё на main — гонок нет).
    private(set) var mode: CallMode = .drive
    private var callContext = ""
    private var userNotes: [String] = []
    private var suggestions: [String] = []
    private var transcript: [String] = []
    private var autoClassified = false
    private var running = false
    private var busy = false
    private var timer: Timer?

    /// Новая строка ассистента (подсказка/заметка) — на main.
    var onAssistant: ((String) -> Void)?
    /// Статус/служебное (смена режима, ошибки) — на main.
    var onStatus: ((String) -> Void)?

    /// Если в первом контексте от Юрия встречается одно из этих слов — listen-mode.
    private static let listenTriggers = [
        "обучен", "лекци", "вебинар", "конференц", "митап", "воркшоп",
        "доклад", "семинар", "учус", "слушаю", "был на", "выступлен",
        "тренинг", "мастер-класс", "мастеркласс",
        "факультет", "курс ", "курсы", "поток ", "интенсив", "марафон",
        "школа ", "академи", "урок", "разбор",
    ]

    init(llm: LLMProvider, cfg: AppConfig) {
        self.llm = llm
        self.cfg = cfg
    }

    // MARK: - Жизненный цикл

    func start() {
        guard !running else { return }
        running = true
        let t = Timer.scheduledTimer(withTimeInterval: cfg.suggestionIntervalSec,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer = t
        if !FileManager.default.fileExists(atPath: resourcesDir.appendingPathComponent("persona.md").path) {
            onStatus?("⚠️ persona.md не найден в \(resourcesDir.path) — подсказки будут общими. Поправь путь в настройках.")
        }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Вход от Юрия (контекст / заметки / смена режима)

    /// Первая фраза = контекст (и детект режима), дальше = заметки. Команды
    /// «я веду» / «я слушаю» переключают режим вручную (как в MVP).
    func provideInput(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let cmd = text.lowercased()
        if callContext.isEmpty {
            callContext = text
            mode = Self.detectMode(text)
            onStatus?(mode == .listen
                ? "✓ Контекст принят. Listen-mode: слушаю, ловлю action items 📌 и важное 🔔."
                : "✓ Контекст принят. Drive-mode: подсказки 💡 пойдут по ходу.")
            return
        }
        if ["я веду", "веду", "drive", "веду звонок", "режим веду"].contains(cmd) {
            mode = .drive; onStatus?("✓ Переключился в drive-mode (ты ведёшь)."); return
        }
        if ["я слушаю", "слушаю", "listen", "listen-mode", "режим слушаю"].contains(cmd) {
            mode = .listen; onStatus?("✓ Переключился в listen-mode (ты слушаешь)."); return
        }
        userNotes.append(text)
        onStatus?("📝 заметка учтена")
    }

    /// Транскрипт-чанк из AudioRecorder (уже отфильтрованный от галлюцинаций).
    func appendTranscript(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        transcript.append(t)
    }

    // MARK: - Тик подсказок

    private func tick() {
        guard running, !busy, !transcript.isEmpty else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            await maybeAutoDetectMode()
            do {
                let out = (mode == .listen) ? try await makeNote() : try await makeSuggestion()
                emit(out)
            } catch {
                onStatus?("⚠️ Ассистент: \(error.localizedDescription)")
            }
        }
    }

    private func emit(_ raw: String) {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !["skip", "пропустить"].contains(clean.lowercased()) else { return }
        suggestions.append(clean)
        onAssistant?(clean)
    }

    // MARK: - Режим

    private static func detectMode(_ text: String) -> CallMode {
        let t = text.lowercased()
        return listenTriggers.contains(where: { t.contains($0) }) ? .listen : .drive
    }

    /// Если Юрий не задал контекст — пробуем определить режим из транскрипта:
    /// быстро по триггер-словам, иначе один раз за сессию — Haiku-классификация.
    private func maybeAutoDetectMode() async {
        guard callContext.isEmpty, mode == .drive, transcript.count >= 2 else { return }
        let head = transcript.prefix(20).joined(separator: " ").lowercased()
        for trig in Self.listenTriggers where head.contains(trig) {
            mode = .listen
            onStatus?("🔄 Слышу обучение/вебинар — listen-mode. Если ты ведёшь — напиши «я веду».")
            return
        }
        guard !autoClassified, transcript.count >= 4 else { return }
        autoClassified = true
        let sample = transcript.prefix(15).joined(separator: "\n")
        let prompt = """
        Определи характер аудио-записи по первым ~30 секундам транскрипта.

        ТРАНСКРИПТ:
        \(sample)

        Это:
        (a) ДИАЛОГ — двое или больше людей переговариваются, есть вопрос-ответ, обращения друг к другу, паузы
        (b) МОНОЛОГ — один спикер (туториал, лекция, видео-курс, презентация, проповедь, обзор продукта)

        Ответ ровно одним словом: "dialog" или "monolog". Без преамбулы и пояснений.
        """
        if let verdict = try? await llm.complete(prompt: prompt, model: cfg.classifyModel, timeout: 30),
           verdict.lowercased().contains("monolog") {
            mode = .listen
            onStatus?("🔄 Похоже на монолог/туториал — listen-mode. Если ты ведёшь звонок — напиши «я веду».")
        }
    }

    // MARK: - Файлы-ресурсы

    private func resource(_ name: String) -> String {
        (try? String(contentsOf: resourcesDir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    private var transcriptTail: String { transcript.suffix(30).joined(separator: "\n") }
    private var notesText: String { userNotes.suffix(10).map { "- \($0)" }.joined(separator: "\n").ifEmpty("пока нет") }
    private var prevSug: String { suggestions.suffix(10).map { "- \($0)" }.joined(separator: "\n").ifEmpty("пока нет") }

    // MARK: - Подсказка (drive)

    private func makeSuggestion() async throws -> String {
        let persona = resource("persona.md")
        let checklist = resource("checklist.json")
        let prompt = """
        Ты — копилот Юрия Солара на текущем звонке. Дай ОДНУ конкретную подсказку (≤15 слов) ИЛИ ответь словом "skip".

        КОНТЕКСТ ЗВОНКА (от Юрия): \(callContext.ifEmpty("не указан"))

        ЗАМЕТКИ ОТ ЮРИЯ В ПРОЦЕССЕ (то что он реально знает / решил):
        \(notesText)

        ПЕРСОНА ЮРИЯ И ЕГО СТИЛЬ:
        \(persona)

        ЧЕК-ЛИСТ ИДЕАЛЬНОГО ЗВОНКА (включая «часто забывает»):
        \(checklist)

        ПРЕДЫДУЩИЕ ПОДСКАЗКИ (не повторять дословно):
        \(prevSug)

        ТРАНСКРИПТ ПОСЛЕДНИХ 30 РЕПЛИК:
        \(transcriptTail)

        Задача: что Юрию стоит ПРЯМО СЕЙЧАС спросить или уточнить?
        Правила:
        - Учитывай заметки Юрия: если он уже сказал «у них своя CRM» — про CRM не спрашивай
        - Учитывай фазу звонка по транскрипту (знакомство/копаем боль/квалификация/закрытие)
        - Приоритет — пункты `often_skipped=true` если они релевантны фазе
        - Не повторяй прошлые подсказки дословно, но можно вернуться к теме если разговор подошёл

        Если уместной подсказки нет — "skip".

        ПРАВИЛА ФОРМЫ:
        - ОДНА короткая строка вопросом или императивом, как живой коуч сказал бы рядом
        - ТОЛЬКО на естественном русском, как живой человек
        - НИКАКИХ snake_case тегов из чек-листа (типа `team_size`, `often_skipped`, `pain_discovery`)
        - Без преамбулы, без эмодзи, без markdown
        """
        let out = try await llm.complete(prompt: prompt, model: cfg.suggestModel, timeout: 60)
        return out.isEmpty ? "skip" : "💡 \(out)"
    }

    // MARK: - Заметка (listen)

    private func makeNote() async throws -> String {
        let listenDoc = resource("listen_mode.md")
        let persona = resource("persona.md")
        let prompt = """
        Ты — копилот Юрия Солара. Он СЛУШАЕТ обучение/лекцию/вебинар, но может
        активно вмешаться: задать вопрос в Q&A, кинуть реплику в чат. Не «болванчик в зале».

        Твоя задача — выдать ОДНУ строку: action / важный тезис / вопрос / реплика в чат / skip.

        КОНТЕКСТ ЗВОНКА (от Юрия): \(callContext.ifEmpty("не указан"))

        ЗАМЕТКИ ЮРИЯ В ПРОЦЕССЕ:
        \(notesText)

        ПРОФИЛЬ ЮРИЯ И ПРАВИЛА LISTEN-MODE:
        \(listenDoc)

        СТИЛЬ ЮРИЯ (для вопросов и реплик — пиши как он сам бы сказал):
        \(persona)

        УЖЕ ВЫДАННЫЕ СТРОКИ (не дублировать):
        \(prevSug)

        ТРАНСКРИПТ ПОСЛЕДНИХ 30 РЕПЛИК:
        \(transcriptTail)

        Реши какой тип сейчас уместен (приоритет: 💡 > 💬 > 📌 > 🔔):

        1. **💡 Спроси** — если спикер ТОЛЬКО ЧТО открыл Q&A («вопросы есть?», «обсудим», пауза для вопросов), или сказал спорное/неполное и надо уточнить
        2. **💬 В чат** — если идёт чат-обсуждение по теме где у Юрия экспертиза (AI/боты/виллы/продажи/контент) и есть момент вступить
        3. **📌 Тебе / Календарь** — обязательное действие лично для Юрия или фиксация даты
        4. **🔔 Важно** — полезный факт/цифра/имя в копилку

        Иначе — `skip`.

        ПРАВИЛА ФОРМЫ:
        - Одна строка начинающаяся с эмодзи-маркера 📌/🔔/💡/💬 либо просто `skip`
        - Только естественный русский, без жаргона и snake_case
        - Без markdown, без других эмодзи кроме указанных
        - Максимум 15-20 слов
        - Не повторять уже выданное
        """
        return try await llm.complete(prompt: prompt, model: cfg.suggestModel, timeout: 60)
    }

    // MARK: - Финальная сводка

    func finalSummary(fullTranscript: String) async -> String {
        let full = fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return "Транскрипта нет — сводки не будет." }
        do {
            return mode == .listen ? try await summarizeListen(full) : try await summarizeDrive(full)
        } catch {
            return "✗ Сводка не получилась: \(error.localizedDescription)"
        }
    }

    private func summarizeDrive(_ full: String) async throws -> String {
        let persona = resource("persona.md")
        let checklist = resource("checklist.json")
        let prompt = """
        Структурная сводка звонка для Юрия Солара.

        КОНТЕКСТ: \(callContext.ifEmpty("не указан"))

        ЗАМЕТКИ ЮРИЯ В ПРОЦЕССЕ:
        \(userNotes.map { "- \($0)" }.joined(separator: "\n").ifEmpty("пусто"))

        ПОЛНЫЙ ТРАНСКРИПТ:
        \(full)

        ПЕРСОНА И ЧЕК-ЛИСТ (для оценки что закрыто/не закрыто):
        \(persona)

        \(checklist)

        Дай отчёт по структуре:

        ✅ Закрыто (что обсудили + ответ):
        [список на естественном русском]

        ⚠ Неполно (обсудили, но ответ невнятный):
        [список на естественном русском]

        ❌ Не задано (важное, что надо было спросить):
        [список на естественном русском]

        → Follow-up на следующий звонок:
        [1-3 строки]

        ПРАВИЛА ЯЗЫКА (СТРОГО):
        - ТОЛЬКО естественный русский язык, как живой человек
        - НИКАКИХ технических id из чек-листа (типа `working_hours`, `existing_automations`, `team_size`)
        - НИКАКИХ snake_case, backticks, скобок с тегами, метаданных
        - Не пиши «пункт N чек-листа» — просто описывай суть человеческими словами
        - Не пиши «discovery/pain_discovery/qualification фаза» — пиши «знакомство», «копаем боль», «квалификация»
        - Без преамбулы, без markdown code-fence
        """
        return try await llm.complete(prompt: prompt, model: cfg.summaryModel, timeout: 300)
    }

    private func summarizeListen(_ full: String) async throws -> String {
        let listenDoc = resource("listen_mode.md")
        let prompt = """
        Финальная сводка обучения/лекции/вебинара для Юрия Солара. Он СЛУШАЛ, не вёл.

        КОНТЕКСТ ОТ ЮРИЯ: \(callContext.ifEmpty("не указан"))

        ЗАМЕТКИ ЮРИЯ В ПРОЦЕССЕ:
        \(userNotes.map { "- \($0)" }.joined(separator: "\n").ifEmpty("пусто"))

        ACTION ITEMS И ВАЖНОЕ, ЧТО УЖЕ БЫЛО ВЫХВАЧЕНО В РЕАЛТАЙМЕ:
        \(suggestions.map { "- \($0)" }.joined(separator: "\n").ifEmpty("пусто"))

        ПРОФИЛЬ ЮРИЯ И ПРАВИЛА LISTEN-MODE:
        \(listenDoc)

        ПОЛНЫЙ ТРАНСКРИПТ:
        \(full)

        Сформируй итоговый отчёт строго по структуре:

        📌 Что мне нужно сделать (action items):
        [список конкретных действий с дедлайнами если есть. Если ничего нет — «нет конкретных задач»]

        🔔 Ключевые факты и цифры:
        [3-7 важных тезисов / метрик / процентов / кейсов из лекции]

        📅 Дедлайны и даты:
        [все упомянутые даты будущих встреч/созвонов/отсечек. Если нет — пропусти секцию]

        👥 Имена / контакты:
        [имена людей которые упоминались как полезные контакты / ответственные / спикеры. Если нет — пропусти]

        💡 Идеи для моего бизнеса:
        [если из услышанного что-то применимо к Solar Property / 4bos / AI-агентам / автоматизации — 1-3 пункта. Если ничего — пропусти секцию]

        📚 Краткий конспект:
        [3-5 строк: основная тема и главные выводы]

        ПРАВИЛА ЯЗЫКА (СТРОГО):
        - ТОЛЬКО естественный русский язык, как живой человек
        - НИКАКИХ snake_case, backticks, технических тегов
        - Без преамбулы, без markdown code-fence
        - Не описывай мета («был обзор такого-то блока») — пиши суть
        """
        return try await llm.complete(prompt: prompt, model: cfg.summaryModel, timeout: 300)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
