import AppKit
import AVFoundation
import Foundation
import WebKit

@MainActor
final class RealtimeVoiceAssistant: NSObject, WKScriptMessageHandler, WKUIDelegate {
    enum State {
        case stopped, connecting, listening, thinking, speaking, failed(String)

        var isActive: Bool {
            switch self { case .stopped, .failed: return false; default: return true }
        }
    }

    /// Хост, который выдаёт временный ключ realtime-голоса (`defaults write com.solar.copilot realtimeTokenHost user@host`).
    /// Пусто = функция недоступна (публичная сборка).
    private let server = UserDefaults.standard.string(forKey: "realtimeTokenHost") ?? ""
    private var panel: NSPanel?
    private var webView: WKWebView?
    private var transport: NativeRealtimeTransport?
    private let speaker = VictoriaSpeaker()
    private let taskRunner = CodexVoiceTaskRunner()
    private var idleStopWorkItem: DispatchWorkItem?
    private var cachedToken: [String: Any]?
    private var cachedTokenUntil = Date.distantPast
    private var tokenRefreshWorkItem: DispatchWorkItem?
    private var webRTCStartTimeoutWorkItem: DispatchWorkItem?
    private var pendingCommand: String?
    private var activationGeneration = 0
    private let idleTimeout: TimeInterval = 30
    private(set) var state: State = .stopped
    var onState: ((State, String) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onConversationReady: (() -> Void)?

    func toggle() {
        state.isActive ? stop() : start()
    }

    func prewarm() {
        guard cachedToken == nil || cachedTokenUntil <= Date() else { return }
        Task { @MainActor in
            if let token = try? await mintToken() {
                cachedToken = token
                cachedTokenUntil = Date().addingTimeInterval(480)
                scheduleTokenRefresh(after: 420)
            } else {
                scheduleTokenRefresh(after: 30)
            }
        }
    }

    private func scheduleTokenRefresh(after delay: TimeInterval) {
        tokenRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cachedToken = nil
            self.cachedTokenUntil = .distantPast
            self.prewarm()
        }
        tokenRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func start(command: String? = nil) {
        if state.isActive {
            if let command { submit(command: command) }
            return
        }
        pendingCommand = command.map(contextualized)
        activationGeneration += 1
        let generation = activationGeneration
        update(.connecting, "Подключаю GPT Live…")
        Task { @MainActor in
            do {
                try await ensureMicrophonePermission()
                guard generation == activationGeneration, state.isActive else { return }
                let token: [String: Any]
                if let cachedToken, cachedTokenUntil > Date() {
                    token = cachedToken
                    self.cachedToken = nil
                    prewarm()
                } else {
                    token = try await mintToken()
                }
                guard generation == activationGeneration, state.isActive else { return }
                guard token["value"] as? String != nil else {
                    throw NSError(domain: "GPTLive", code: 7,
                                  userInfo: [NSLocalizedDescriptionKey: "временный ключ GPT повреждён"])
                }
                // WKWebView getUserMedia is a confirmed stall on this Mac even
                // with system permission and audio-input entitlement. Starting
                // the proven native transport directly removes an 8-second dead
                // path and keeps the WebRTC implementation available as rollback.
                AudioRecorder.log("GPT Live starting native transport")
                startNativeTransport(token: token, generation: generation)
            } catch {
                guard generation == activationGeneration else { return }
                update(.failed(error.localizedDescription), "GPT Live: \(error.localizedDescription)")
                transport?.stop()
                transport = nil
            }
        }
    }

    func submit(command: String) {
        cancelIdleShutdown()
        let prepared = contextualized(command)
        guard state.isActive else {
            start(command: command)
            return
        }
        if case .connecting = state {
            pendingCommand = prepared
            return
        }
        update(.thinking, "Думаю…")
        if let transport {
            transport.sendUserText(prepared)
            return
        }
        if webView != nil {
            sendWebRTCUserText(prepared)
        } else {
            pendingCommand = prepared
        }
    }

    private func contextualized(_ command: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = TimeZone(identifier: "Asia/Makassar")
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss zzz"
        return "Системный контекст: сейчас \(formatter.string(from: Date())). Запрос Юрия: \(command)"
    }

    func stop() {
        // Invalidate an in-flight permission/token/WebView start before releasing audio.
        activationGeneration += 1
        webRTCStartTimeoutWorkItem?.cancel()
        webRTCStartTimeoutWorkItem = nil
        idleStopWorkItem?.cancel()
        idleStopWorkItem = nil
        speaker.stop()
        pendingCommand = nil
        transport?.stop()
        transport = nil
        if webView != nil { webView?.evaluateJavaScript("window.stopSolarRealtime && window.stopSolarRealtime()") }
        stopWebView()
        update(.stopped, "Голосовой режим выключен")
    }

    private func armIdleShutdown() {
        idleStopWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.state.isActive else { return }
            self.onTranscript?("Альтрон: 30 секунд тишины — жду ключевое слово")
            self.stop()
        }
        idleStopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: item)
    }

    private func cancelIdleShutdown() {
        idleStopWorkItem?.cancel()
        idleStopWorkItem = nil
    }

    private func isStopIntent(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "[^а-яa-z0-9 ]", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let exactPhrases = [
            "стоп", "хватит", "закончили", "заканчиваем", "заканчивай",
            "все хватит на сегодня", "хватит на сегодня", "закончим на сегодня",
            "все на сегодня", "альтрон отключись", "альтрон выключись",
            "стоп альтрон", "до завтра", "до свидания", "все отключайся",
            "разговор завершен", "заверши разговор", "завершаем разговор",
            "отключись", "выключись", "на сегодня все", "спасибо все",
        ]
        if exactPhrases.contains(normalized) { return true }
        let contextualPhrases = [
            "хватит на сегодня", "закончим на сегодня", "все на сегодня",
            "альтрон отключись", "альтрон выключись", "стоп альтрон",
            "разговор завершен", "заверши разговор", "завершаем разговор",
            "на сегодня все", "спасибо все",
        ]
        return contextualPhrases.contains(where: normalized.contains)
    }

    private func update(_ newState: State, _ text: String) {
        state = newState
        onState?(newState, text)
    }

    private func mintToken() async throws -> [String: Any] {
        guard !server.isEmpty else {
            throw NSError(domain: "GPTLive", code: 3, userInfo: [NSLocalizedDescriptionKey: "голосовой ассистент не настроен (realtimeTokenHost)"])
        }
        let data = try await RemoteProcess.run(
            executable: "/usr/bin/ssh",
            arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", server, "/opt/desktop_realtime_token.py"],
            timeout: 40
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "GPTLive", code: 1, userInfo: [NSLocalizedDescriptionKey: "сервер вернул неверный токен"])
        }
        let value = (object["value"] as? String)
            ?? ((object["client_secret"] as? [String: Any])?["value"] as? String)
        guard let value, !value.isEmpty else {
            throw NSError(domain: "GPTLive", code: 2, userInfo: [NSLocalizedDescriptionKey: "в ответе нет временного ключа"])
        }
        return ["value": value, "model": "gpt-realtime-2.1"]
    }

    private func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let allowed = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            if allowed { return }
            fallthrough
        case .denied, .restricted:
            throw NSError(domain: "GPTLive", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "разреши микрофон для Solar Copilot в Системных настройках → Конфиденциальность и безопасность → Микрофон"])
        @unknown default:
            throw NSError(domain: "GPTLive", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "macOS не дала доступ к микрофону"])
        }
    }

    private func buildWebViewIfNeeded() {
        guard webView == nil else { return }
        let content = WKUserContentController()
        content.add(self, name: "voiceAssistant")
        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        let p = NSPanel(contentRect: NSRect(x: -20, y: -20, width: 2, height: 2),
                        styleMask: [.borderless], backing: .buffered, defer: false)
        p.alphaValue = 0.01
        p.ignoresMouseEvents = true
        p.contentView = web
        p.orderFrontRegardless()
        web.loadHTMLString(Self.html, baseURL: URL(string: "https://localhost"))
        panel = p
        webView = web
    }

    private func stopWebView() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "voiceAssistant")
        webView?.stopLoading()
        panel?.close()
        webView = nil
        panel = nil
    }

    private func evaluate(_ javaScript: String) async throws {
        guard let webView else { throw NSError(domain: "GPTLive", code: 3) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(javaScript) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func waitForBridge() async throws {
        for _ in 0..<50 {
            if let ready = try? await evaluateValue("typeof window.startSolarRealtime === 'function'"),
               ready as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "GPTLive", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "голосовой мост не загрузился"])
    }

    private func startNativeTransport(token: [String: Any], generation: Int) {
        guard generation == activationGeneration, state.isActive,
              let secret = token["value"] as? String else { return }
        webRTCStartTimeoutWorkItem?.cancel()
        webRTCStartTimeoutWorkItem = nil
        stopWebView()
        let native = NativeRealtimeTransport()
        native.onEvent = { [weak self] event in self?.handleRealtimeEvent(event) }
        native.onFailure = { [weak self] message in
            guard let self, generation == self.activationGeneration else { return }
            self.transport?.stop()
            self.transport = nil
            self.update(.failed(message), "GPT Live: \(message)")
        }
        let initial = pendingCommand
        pendingCommand = nil
        transport = native
        do {
            try native.start(secret: secret,
                             model: token["model"] as? String ?? "gpt-realtime-2.1",
                             initialText: initial)
            update(.connecting, "Подключаю микрофон…")
        } catch {
            transport = nil
            update(.failed(error.localizedDescription), "GPT Live: \(error.localizedDescription)")
        }
    }

    private func evaluateValue(_ javaScript: String) async throws -> Any? {
        guard let webView else { throw NSError(domain: "GPTLive", code: 3) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(javaScript) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            webRTCStartTimeoutWorkItem?.cancel()
            webRTCStartTimeoutWorkItem = nil
            AudioRecorder.log("GPT Live WebRTC ready")
            if let command = pendingCommand {
                pendingCommand = nil
                update(.thinking, "Думаю…")
                sendWebRTCUserText(command)
            } else {
                update(.listening, "Слушаю")
                armIdleShutdown()
            }
        case "progress":
            if let text = body["message"] as? String { update(.connecting, text) }
        case "speech_started":
            update(.listening, "Слушаю")
        case "speech_stopped": update(.thinking, "Думаю…")
        case "transcript":
            if let text = body["text"] as? String { onTranscript?("Вы: \(text)") }
        case "assistant_text":
            guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            onTranscript?("Альтрон: \(text)")
        case "response_started": update(.speaking, "Отвечаю…")
        case "response_done":
            if state.isActive {
                update(.listening, "Слушаю")
                armIdleShutdown()
            }
        case "tool":
            guard let callID = body["call_id"] as? String,
                  let name = body["name"] as? String else { return }
            let arguments = body["arguments"] as? String ?? "{}"
            update(.thinking, "Codex выполняет задачу…")
            Task { @MainActor in
                let output = await taskRunner.handle(name: name, argumentsJSON: arguments)
                sendToolResult(callID: callID, output: output)
            }
        case "error":
            webRTCStartTimeoutWorkItem?.cancel()
            webRTCStartTimeoutWorkItem = nil
            let text = body["message"] as? String ?? "неизвестная ошибка"
            AudioRecorder.log("GPT Live WebRTC error: \(text)")
            update(.failed(text), "GPT Live: \(text)")
        default: break
        }
    }

    private func handleRealtimeEvent(_ event: [String: Any]) {
        // После stop/idle queued WebSocket events не имеют права снова запустить TTS.
        guard state.isActive else { return }
        guard let type = event["type"] as? String else { return }
        switch type {
        case "session.created", "session.updated":
            if let command = pendingCommand {
                pendingCommand = nil
                update(.thinking, "Думаю…")
                transport?.sendUserText(command)
            } else {
                update(.listening, "Слушаю")
                armIdleShutdown()
            }
        case "input_audio_buffer.speech_started":
            cancelIdleShutdown()
            speaker.stop()
            update(.listening, "Слушаю")
        case "input_audio_buffer.speech_stopped":
            cancelIdleShutdown()
            update(.thinking, "Думаю…")
        case "conversation.item.input_audio_transcription.completed":
            if let text = event["transcript"] as? String {
                onTranscript?("Вы: \(text)")
                if isStopIntent(text) {
                    onTranscript?("Альтрон: разговор завершён; снова включусь по слову «Альтрон»")
                    stop()
                }
            }
        case "response.created":
            update(.speaking, "Отвечаю…")
        case "response.output_audio_transcript.done":
            if let text = event["transcript"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onTranscript?("Альтрон: \(text)")
            }
        case "response.done":
            break
        case "local.playback_done":
            if state.isActive {
                update(.listening, "Слушаю продолжение…")
                onConversationReady?()
                armIdleShutdown()
            }
        case "local.barge_in":
            if state.isActive {
                cancelIdleShutdown()
                update(.listening, "Слушаю продолжение…")
            }
        case "response.function_call_arguments.done":
            guard let callID = event["call_id"] as? String,
                  let name = event["name"] as? String else { return }
            if name == "end_conversation" {
                onTranscript?("Альтрон: разговор завершён; снова включусь по слову «Альтрон»")
                stop()
                return
            }
            let arguments = event["arguments"] as? String ?? "{}"
            update(.thinking, "Codex выполняет задачу…")
            Task { @MainActor in
                let output = await taskRunner.handle(name: name, argumentsJSON: arguments)
                transport?.sendToolResult(callID: callID, output: output)
            }
        case "error":
            let nested = event["error"] as? [String: Any]
            let text = nested?["message"] as? String ?? "неизвестная ошибка Realtime"
            transport?.stop()
            transport = nil
            update(.failed(text), "GPT Live: \(text)")
        default:
            break
        }
    }

    private func speakAnswer(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelIdleShutdown()
        // Иначе встроенный микрофон слышит MiniMax из динамиков, VAD принимает
        // это за перебивание и рубит ответ на куски.
        transport?.setMicrophoneMuted(true)
        onTranscript?("Альтрон: \(text)")
        update(.speaking, "Отвечаю…")
        speaker.speak(text: text, server: server) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.transport?.setMicrophoneMuted(false)
                switch result {
                case .success:
                    if self.state.isActive {
                        self.update(.listening, "Слушаю")
                        self.armIdleShutdown()
                    }
                case .failure(let error): self.update(.failed(error.localizedDescription), "Голос: \(error.localizedDescription)")
                }
            }
        }
    }

    private func sendToolResult(callID: String, output: String) {
        if let transport {
            transport.sendToolResult(callID: callID, output: output)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["call_id": callID, "output": output]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.solarToolResult(\(json))")
    }

    private func sendWebRTCUserText(_ text: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["text": text]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.solarSendUserText(\(json)); true") { _, error in
            if let error { AudioRecorder.log("GPT Live WebRTC send text failed: \(error.localizedDescription)") }
        }
    }

    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        AudioRecorder.log("GPT Live WebRTC media permission origin=\(origin.protocol)://\(origin.host) type=\(type.rawValue)")
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    private static let html = #"""
    <!doctype html><meta charset="utf-8"><script>
    let pc, dc, stream, remoteAudio;
    const native = (x) => window.webkit.messageHandlers.voiceAssistant.postMessage(x);
    function findText(value) {
      if (!value) return "";
      if (typeof value === "string") return value;
      if (Array.isArray(value)) return value.map(findText).filter(Boolean).join(" ");
      if (typeof value === "object") {
        if (typeof value.text === "string") return value.text;
        if (typeof value.transcript === "string") return value.transcript;
        return findText(value.content || value.output);
      }
      return "";
    }
    function send(event) { if (dc && dc.readyState === "open") dc.send(JSON.stringify(event)); }
    window.startSolarRealtime = async function(secret) {
      try {
        native({type:"progress", message:"Настраиваю разговор…"});
        pc = new RTCPeerConnection();
        remoteAudio = document.createElement("audio");
        remoteAudio.autoplay = true;
        remoteAudio.playsInline = true;
        remoteAudio.volume = 1.0;
        document.body.appendChild(remoteAudio);
        pc.ontrack = (event) => {
          remoteAudio.srcObject = event.streams[0] || new MediaStream([event.track]);
          remoteAudio.play().catch(() => {});
        };
        dc = pc.createDataChannel("oai-events");
        dc.onopen = () => native({type:"ready"});
        dc.onmessage = (event) => {
          const e = JSON.parse(event.data);
          if (e.type === "input_audio_buffer.speech_started") native({type:"speech_started"});
          if (e.type === "input_audio_buffer.speech_stopped") native({type:"speech_stopped"});
          if (e.type === "conversation.item.input_audio_transcription.completed") native({type:"transcript", text:e.transcript || ""});
          if (e.type === "response.created") native({type:"response_started"});
          if (e.type === "response.output_audio_transcript.done" && e.transcript) {
            native({type:"assistant_text", text:e.transcript});
            window.__lastTextDone = true;
          }
          if (e.type === "response.output_text.done" && e.text) native({type:"assistant_text", text:e.text});
          if (e.type === "response.function_call_arguments.done") native({type:"tool", call_id:e.call_id, name:e.name, arguments:e.arguments || "{}"});
          if (e.type === "response.done") {
            const text = findText(e.response && e.response.output);
            const hasTool = JSON.stringify(e.response && e.response.output || []).includes('function_call');
            if (text && !hasTool && !window.__lastTextDone) native({type:"assistant_text", text});
            window.__lastTextDone = false;
          }
          if (e.type === "response.output_text.done") window.__lastTextDone = true;
          if (e.type === "response.done") native({type:"response_done"});
          if (e.type === "error") native({type:"error", message:(e.error && e.error.message) || "Realtime error"});
        };
        native({type:"progress", message:"Подключаю микрофон…"});
        const micRequest = navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true}, video:false});
        const micTimeout = new Promise((_, reject) => setTimeout(() => reject(new Error("microphone capture timed out")), 10000));
        stream = await Promise.race([micRequest, micTimeout]);
        native({type:"progress", message:"Микрофон подключён, соединяюсь с GPT…"});
        stream.getTracks().forEach(track => pc.addTrack(track, stream));
        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        const response = await fetch("https://api.openai.com/v1/realtime/calls", {
          method:"POST", body:offer.sdp,
          headers:{Authorization:`Bearer ${secret.value}`, "Content-Type":"application/sdp"}
        });
        if (!response.ok) throw new Error(`OpenAI ${response.status}: ${await response.text()}`);
        await pc.setRemoteDescription({type:"answer", sdp:await response.text()});
        native({type:"progress", message:"GPT подключён, включаю канал…"});
      } catch (e) { native({type:"error", message:String(e && e.message || e)}); }
    };
    window.solarToolResult = function(payload) {
      send({type:"conversation.item.create", item:{type:"function_call_output", call_id:payload.call_id, output:payload.output}});
      send({type:"response.create"});
    };
    window.solarSendUserText = function(payload) {
      const text = String(payload && payload.text || "").trim();
      if (!text) return;
      send({type:"conversation.item.create", item:{type:"message", role:"user", content:[{type:"input_text", text}]}});
      send({type:"response.create"});
    };
    window.stopSolarRealtime = function() {
      if (stream) stream.getTracks().forEach(t => t.stop());
      if (remoteAudio) { remoteAudio.pause(); remoteAudio.srcObject = null; }
      if (dc) dc.close(); if (pc) pc.close();
      stream = null; dc = null; pc = null;
    };
    </script>
    """#
}

enum RemoteProcess {
    static func run(executable: String, arguments: [String], input: Data? = nil, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("solar-voice-\(UUID().uuidString).out")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: output) else {
                continuation.resume(throwing: NSError(domain: "RemoteProcess", code: 1)); return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = handle
            let errorPipe = Pipe()
            process.standardError = errorPipe
            let inputPipe = Pipe()
            if input != nil { process.standardInput = inputPipe }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            process.terminationHandler = { p in
                killer.cancel(); try? handle.close()
                let data = (try? Data(contentsOf: output)) ?? Data()
                try? FileManager.default.removeItem(at: output)
                let err = (try? errorPipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if p.terminationStatus == 0 { continuation.resume(returning: data) }
                else { continuation.resume(throwing: NSError(domain: "RemoteProcess", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err.trimmingCharacters(in: .whitespacesAndNewlines)])) }
            }
            do {
                try process.run()
                if let input { inputPipe.fileHandleForWriting.write(input); try? inputPipe.fileHandleForWriting.close() }
            } catch {
                killer.cancel(); try? handle.close(); try? FileManager.default.removeItem(at: output)
                continuation.resume(throwing: error)
            }
        }
    }
}

@MainActor
final class VictoriaSpeaker: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: ((Result<Void, Error>) -> Void)?

    func speak(text: String, server: String, completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        self.completion = completion
        Task { @MainActor in
            do {
                let audio = try await RemoteProcess.run(
                    executable: "/usr/bin/ssh",
                    arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", server, "/opt/desktop_victoria_tts.py"],
                    input: Data(text.utf8), timeout: 55)
                let p = try AVAudioPlayer(data: audio)
                p.delegate = self
                p.prepareToPlay(); player = p
                guard p.play() else { throw NSError(domain: "Victoria", code: 2, userInfo: [NSLocalizedDescriptionKey: "не удалось включить звук"]) }
            } catch { finish(.failure(error)) }
        }
    }

    func stop() {
        player?.stop(); player = nil
        completion = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(flag ? .success(()) : .failure(NSError(domain: "Victoria", code: 3)))
    }

    private func finish(_ result: Result<Void, Error>) {
        player = nil
        let callback = completion; completion = nil
        callback?(result)
    }
}
