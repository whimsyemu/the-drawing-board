import Foundation
import WebKit
import Speech
import AVFoundation

/// Gives the page a working `SpeechRecognition` so its "click to speak" button
/// works inside the app. The page thinks it is talking to the browser's speech
/// engine; we hand the audio to Apple's on-device recogniser (on-device whenever
/// the device supports it) and hand the words back.
final class SpeechBridge: NSObject, WKScriptMessageHandler {

    static let handlerName = "speech"

    /// Injected at document start, before the page checks whether speech exists.
    static let polyfill = """
    (function(){
      if (window.SpeechRecognition || window.webkitSpeechRecognition) return;
      var active = null;
      function post(msg){ try { window.webkit.messageHandlers.speech.postMessage(msg); } catch (e) {} }
      function SR(){ this.continuous = false; this.interimResults = false; this.lang = 'en-US';
                     this.onresult = null; this.onerror = null; this.onend = null; this.onstart = null; }
      SR.prototype.start = function(){ active = this; post({op:'start', lang: this.lang || 'en-US'}); };
      SR.prototype.stop  = function(){ post({op:'stop'}); };
      SR.prototype.abort = SR.prototype.stop;
      window.__speechEvent = function(type, payload){
        var r = active; if (!r) return; payload = payload || {};
        if (type === 'start')  { if (r.onstart) r.onstart({}); return; }
        if (type === 'result') { var alt = {transcript: String(payload.transcript || ''), confidence: 1};
                                 var res = [alt]; res.isFinal = !!payload.isFinal;
                                 if (r.onresult) r.onresult({resultIndex: 0, results: [res]}); return; }
        if (type === 'error')  { if (r.onerror) r.onerror({error: payload.error || 'aborted'}); return; }
        if (type === 'end')    { if (active === r) active = null; if (r.onend) r.onend({}); }
      };
      window.SpeechRecognition = SR; window.webkitSpeechRecognition = SR;
    })();
    """

    private weak var webView: WKWebView?
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastText = ""
    private var ended = true

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return }
        if op == "start" { start(lang: (body["lang"] as? String) ?? "en-US") } else { stop() }
    }

    private func emit(_ type: String, _ payload: [String: Any] = [:]) {
        guard let webView, let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            webView.evaluateJavaScript("window.__speechEvent && window.__speechEvent(\"\(type)\", \(json));", completionHandler: nil)
        }
    }

    private func finish(withError error: String? = nil) {
        guard !ended else { return }
        ended = true
        teardown()
        if let error { emit("error", ["error": error]) }
        emit("end")
    }

    private func start(lang: String) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            guard status == .authorized else { self.ended = false; self.finish(withError: "not-allowed"); return }
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                guard granted else { self.ended = false; self.finish(withError: "not-allowed"); return }
                DispatchQueue.main.async { self.begin(lang: lang) }
            }
        }
    }

    private func begin(lang: String) {
        teardown()
        ended = false
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: lang)) ?? SFSpeechRecognizer(), rec.isAvailable else {
            finish(withError: "audio-capture"); return
        }
        recognizer = rec
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { finish(withError: "audio-capture"); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        audioEngine.prepare()
        do { try audioEngine.start() } catch { finish(withError: "audio-capture"); return }

        lastText = ""
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self, !self.ended else { return }
            if let result {
                self.lastText = result.bestTranscription.formattedString
                self.emit("result", ["transcript": self.lastText, "isFinal": result.isFinal])
                if result.isFinal { self.finish() }
            }
            if error != nil { self.finish() }
        }
        emit("start")
    }

    private func stop() {
        guard !ended else { return }
        request?.endAudio()
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        // If the recogniser doesn't deliver its final word promptly, close out with what we have.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.ended else { return }
            self.emit("result", ["transcript": self.lastText, "isFinal": true])
            self.finish()
        }
    }

    private func teardown() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil; request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
