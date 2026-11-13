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

    // Зрение по экрану (vision): кадр главного дисплея уходит в Claude вместе с
    // транскриптом. Гибрид — авто-таймер + кнопка «глянь сейчас».
    private var screenVision: Bool
    private var lastShot: URL?
    private var screenTimer: Timer?

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
        self.screenVision = cfg.screenVisionEnabled
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
        startScreenCapture()
        if !FileManager.default.fileExists(atPath: resourcesDir.appendingPathComponent("persona.md").path) {
            onStatus?("ℹ️ Использую дефолтный профиль подсказок. Свой persona.md положи в \(resourcesDir.path) — и копилот зазвучит твоим голосом.")
        }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        screenTimer?.invalidate()
        screenTimer = nil
        lastShot = nil
    }

    // MARK: - Зрение по экрану

    /// Авто-захват кадра по таймеру (реже подсказок). Кадр приложится к следующей
    /// подсказке. Нет доступа к записи экрана → мягко подсказываем выдать.
    private func startScreenCapture() {
        guard screenVision else { return }
        guard ScreenCapturer.hasPermission() else {
            onStatus?("👁 Чтобы копилот видел экран — выдай «Запись экрана» (меню → 👁 Глянь на экран).")
            return
        }
        captureFrame()
        let iv = max(20.0, cfg.screenCaptureIntervalSec)
        screenTimer?.invalidate()
        screenTimer = Timer.scheduledTimer(withTimeInterval: iv, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureFrame() }
        }
    }

    private func captureFrame() {
        if let url = ScreenCapturer.capture() { lastShot = url }
    }

    /// Путь к свежему кадру для приложения к подсказке (если зрение вкл и файл есть).
    private func currentScreenshotPath() -> String? {
        guard screenVision, let u = lastShot, FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u.path
    }

    /// Кнопка «глянь на экран сейчас» — мгновенный кадр + подсказка по нему,
    /// даже если транскрипт пока тонкий.
    func captureNow() {
        guard ScreenCapturer.hasPermission() else {
            ScreenCapturer.requestPermission()
            onStatus?("👁 Запросил доступ к экрану. Выдай «Запись экрана» в Системных настройках и нажми ещё раз.")
            return
        }
        screenVision = true
        captureFrame()
        onStatus?("👁 Смотрю на экран…")
        guard running, !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { emit(try await makeSuggestion()) }
            catch { onStatus?("⚠️ Ассистент: \(error.localizedDescription)") }
        }
    }

    /// Тумблер зрения из меню по ходу сессии.
    func setScreenVision(enabled: Bool) {
        screenVision = enabled
        if enabled { startScreenCapture() }
        else {
            screenTimer?.invalidate(); screenTimer = nil; lastShot = nil
            onStatus?("👁 Зрение по экрану выключено.")
        }
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
        // Не выпускать в подсказки утечку ошибок claude -p (auth/401/billing в stdout).
        let low = clean.lowercased()
        if low.contains("authenticate") || low.contains("api error") || low.contains("401 ")
            || low.contains("organization has disabled") || low.contains("invalid api key") {
            onStatus?("⚠️ Claude не ответил (auth) — подсказка пропущена.")
            return
        }
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

    /// Ресурс копилота: сначала личный файл пользователя (resourcesDir, приоритет),
    /// иначе дефолтный шаблон из бандла (`copilot-templates/` — чтобы у друга подсказки
    /// работали без личной персоны Юрия).
    private func resource(_ name: String) -> String {
        let userFile = resourcesDir.appendingPathComponent(name)
        if let s = try? String(contentsOf: userFile, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        if let res = Bundle.main.resourcePath {
            let tmpl = URL(fileURLWithPath: res)
                .appendingPathComponent("copilot-templates").appendingPathComponent(name)
            if let s = try? String(contentsOf: tmpl, encoding: .utf8) { return s }
        }
        return ""
    }

    private var transcriptTail: String { transcript.suffix(30).joined(separator: "\n") }
    private var notesText: String { userNotes.suffix(10).map { "- \($0)" }.joined(separator: "\n").ifEmpty("пока нет") }
    private var prevSug: String { suggestions.suffix(10).map { "- \($0)" }.joined(separator: "\n").ifEmpty("пока нет") }

    // MARK: - Подсказка (drive)

    private func makeSuggestion() async throws -> String {
        let persona = resource("persona.md")
        let checklist = resource("checklist.json")
        let examples = resource("hint_examples.md")
        let prompt = """
        Ты — копилот Юрия Солара на живом звонке. Юрий ВЕДЁТ разговор и краем глаза
        ловит твою подсказку. Нужна не вопрос-напоминалка, а готовый тактический ход:
        что сказать ПРЯМО СЕЙЧАС и как подать, чтобы продвинуть сделку.

        Верни ОДНУ подсказку по форме ниже ИЛИ ровно слово "skip", если момент не созрел.

        КОНТЕКСТ ЗВОНКА (от Юрия): \(callContext.ifEmpty("не указан"))

        ЗАМЕТКИ ЮРИЯ В ПРОЦЕССЕ (что он уже знает / решил — не противоречь):
        \(notesText)

        ПЕРСОНА, СТИЛЬ И ПРИЁМЫ ЮРИЯ (формулируй его голосом; бери его обработку возражений и pricing-ходы):
        \(persona)

        ЧЕК-ЛИСТ ИДЕАЛЬНОГО ЗВОНКА (важное, что часто забывает спросить):
        \(checklist)

        ЭТАЛОННЫЕ ПОДСКАЗКИ — вот такой глубины и пользы ждут от тебя (копируй СТИЛЬ и СТРУКТУРУ, не содержание):
        \(examples.ifEmpty("(файл примеров не найден — держи планку: готовая реплика голосом Юрия + одна строка рамки)"))

        ПРЕДЫДУЩИЕ ПОДСКАЗКИ (не повторять):
        \(prevSug)

        ТРАНСКРИПТ ПОСЛЕДНИХ РЕПЛИК:
        \(transcriptTail)

        КОГДА ПОДСКАЗЫВАТЬ (приоритет сверху вниз):
        1. Клиент возразил/засомневался (дорого / справлюсь ли / случай сложный / вдруг отвалишься) → готовая реплика снятия по приёмам Юрия из персоны.
        2. Клиент боится денег/стоимости → разверни в конкретику: из чего реально складывается, почему это копейки, якорь на одну сделку / ROI.
        3. Зашёл разговор о цене → фазовая подача (вход дёшево, окупается с первой продажи, дальше по факту) + якорь «студия взяла бы в разы дороже». Полную сумму не называй первой.
        4. Клиент описал боль/идею своими словами → свяжи его формулировку с твоим решением его же терминами («то, что ты называешь X — это и есть Y, мы это и строим»).
        5. Клиент перегружен/путается → упрости до одного следующего шага.
        6. Момент закрытия → зафиксируй конкретный next step (доступ к данным/коду, дата созвона, кто что готовит).
        7. Если живого нет, но по фазе повис важный незаданный вопрос из чек-листа (бюджет/срок/ЛПР/критерий успеха) → подскажи его задать.

        ФОРМА ОТВЕТА:
        - Начни с готовой реплики, которую Юрий может почти дословно произнести — в кавычках, его голосом.
        - Если нужно — добавь ОДНУ короткую строку рамки (как подать / чего избежать). Без неё, если реплика самодостаточна.
        - 1–6 строк, плотно, без воды. Без преамбулы, без markdown-заголовков, без объяснений что это подсказка.
        - Живой естественный русский. Никаких snake_case тегов из чек-листа (team_size, often_skipped, pain_discovery).
        - Не выдумывай фактов, которых нет в транскрипте/заметках/контексте — цифры и имена бери из разговора.
        - Если по-настоящему нечего добавить прямо сейчас — верни одно слово: skip
        """
        let shot = currentScreenshotPath()
        let out: String
        if let shot = shot {
            let visionPrompt = prompt + """


            НА ЭКРАНЕ СЕЙЧАС: тебе приложен скриншот экрана Юрия (демо/код/сайт/таблица клиента). \
            Открой его и учитывай, что на нём — но только если это релевантно текущему моменту разговора. \
            Если на экране есть конкретика (цифры, поля, ошибки, цена) — опирайся на неё в подсказке.
            """
            out = try await llm.complete(prompt: visionPrompt, imagePaths: [shot], model: cfg.suggestModel, timeout: 120)
        } else {
            out = try await llm.complete(prompt: prompt, model: cfg.suggestModel, timeout: 90)
        }
        let clean = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || ["skip", "пропустить"].contains(clean.lowercased()) { return "skip" }
        return "💡 \(clean)"
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
        - Никогда не включай в сводку пароли, коды доступа, токены, API-ключи и другие секреты, даже если они прозвучали в звонке
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
