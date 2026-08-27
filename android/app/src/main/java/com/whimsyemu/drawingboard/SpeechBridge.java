package com.whimsyemu.drawingboard;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;

import org.json.JSONObject;

import java.util.ArrayList;

/** Backs the page's "click to speak" button with Android's speech recogniser.
 *  Keeps listening across pauses until the page says stop. */
public class SpeechBridge {

    static final int REQUEST_AUDIO = 7;

    /** Injected into the page before its own scripts run (see MainActivity). */
    static final String POLYFILL =
        "(function(){ if (window.SpeechRecognition || window.webkitSpeechRecognition) return;" +
        " var active = null;" +
        " function SR(){ this.continuous=false; this.interimResults=false; this.lang='en-US'; this.onresult=null; this.onerror=null; this.onend=null; this.onstart=null; }" +
        " SR.prototype.start = function(){ active = this; try { AndroidSpeech.start(this.lang || 'en-US'); } catch(e){} };" +
        " SR.prototype.stop  = function(){ try { AndroidSpeech.stop(); } catch(e){} };" +
        " SR.prototype.abort = SR.prototype.stop;" +
        " window.__speechEvent = function(type, payload){ var r = active; if (!r) return; payload = payload || {};" +
        "   if (type === 'start')  { if (r.onstart) r.onstart({}); return; }" +
        "   if (type === 'result') { var alt = {transcript: String(payload.transcript || ''), confidence: 1}; var res = [alt]; res.isFinal = !!payload.isFinal; if (r.onresult) r.onresult({resultIndex: 0, results: [res]}); return; }" +
        "   if (type === 'error')  { if (r.onerror) r.onerror({error: payload.error || 'aborted'}); return; }" +
        "   if (type === 'end')    { if (active === r) active = null; if (r.onend) r.onend({}); } };" +
        " window.SpeechRecognition = SR; window.webkitSpeechRecognition = SR; })();";

    private final Activity activity;
    private final WebView web;
    private final Handler main = new Handler(Looper.getMainLooper());
    private SpeechRecognizer recognizer;
    private boolean listening = false;
    private boolean ended = true;
    private String lang = "en-US";

    SpeechBridge(Activity activity, WebView web) { this.activity = activity; this.web = web; }

    @JavascriptInterface
    public void start(String lang) { this.lang = lang == null ? "en-US" : lang; main.post(this::begin); }

    @JavascriptInterface
    public void stop() { main.post(() -> { listening = false; if (recognizer != null) recognizer.stopListening(); main.postDelayed(() -> finish(null), 1500); }); }

    private void emit(String type, String transcript, boolean isFinal, String error) {
        try {
            JSONObject o = new JSONObject();
            if (transcript != null) { o.put("transcript", transcript); o.put("isFinal", isFinal); }
            if (error != null) o.put("error", error);
            String js = "window.__speechEvent && window.__speechEvent(" + JSONObject.quote(type) + ", " + o + ");";
            main.post(() -> web.evaluateJavascript(js, null));
        } catch (Exception ignored) {}
    }

    private void finish(String error) {
        if (ended) return;
        ended = true; listening = false;
        if (recognizer != null) { try { recognizer.cancel(); } catch (Exception ignored) {} }
        if (error != null) emit("error", null, false, error);
        emit("end", null, false, null);
    }

    void onPermissionResult(boolean granted) { if (granted) begin(); else { ended = false; finish("not-allowed"); } }

    private void begin() {
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQUEST_AUDIO);
            return;
        }
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) { ended = false; finish("audio-capture"); return; }
        if (recognizer == null) {
            recognizer = SpeechRecognizer.createSpeechRecognizer(activity);
            recognizer.setRecognitionListener(new RecognitionListener() {
                public void onReadyForSpeech(Bundle b) {}
                public void onBeginningOfSpeech() {}
                public void onRmsChanged(float v) {}
                public void onBufferReceived(byte[] bytes) {}
                public void onEndOfSpeech() {}
                public void onPartialResults(Bundle b) {
                    ArrayList<String> r = b.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
                    if (r != null && !r.isEmpty() && !ended) emit("result", r.get(0), false, null);
                }
                public void onResults(Bundle b) {
                    ArrayList<String> r = b.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
                    if (r != null && !r.isEmpty() && !ended) emit("result", r.get(0) + " ", true, null);
                    if (listening) listenOnce(); else finish(null);
                }
                public void onError(int code) {
                    if (ended) return;
                    boolean soft = code == SpeechRecognizer.ERROR_NO_MATCH || code == SpeechRecognizer.ERROR_SPEECH_TIMEOUT;
                    if (listening && soft) { listenOnce(); return; }
                    finish(code == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ? "not-allowed" : (soft ? null : "audio-capture"));
                }
                public void onEvent(int i, Bundle b) {}
            });
        }
        ended = false; listening = true;
        emit("start", null, false, null);
        listenOnce();
    }

    private void listenOnce() {
        Intent i = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang)
                .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true);
        try { recognizer.startListening(i); } catch (Exception e) { finish("audio-capture"); }
    }

    void destroy() { if (recognizer != null) { recognizer.destroy(); recognizer = null; } }
}
