package com.whimsyemu.drawingboard;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.util.Base64;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import androidx.core.content.FileProvider;
import androidx.webkit.WebViewAssetLoader;

import java.io.File;
import java.io.FileOutputStream;

/** Hosts The Drawing Board (one self-contained HTML page shipped inside the app).
 *  Everything the person writes stays in this app's own web storage on the device. */
public class MainActivity extends Activity {

    private WebView web;

    // Served from a private https origin so localStorage persists and secure-context APIs work.
    private static final String HOST = "appassets.androidplatform.net";
    private static final String START = "https://" + HOST + "/assets/index.html";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        web = new WebView(this);
        web.setBackgroundColor(0xFF241F38);
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setSupportZoom(false);
        s.setTextZoom(100);

        final WebViewAssetLoader loader = new WebViewAssetLoader.Builder()
                .addPathHandler("/assets/", new WebViewAssetLoader.AssetsPathHandler(this))
                .build();

        web.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                return loader.shouldInterceptRequest(request.getUrl());
            }
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri url = request.getUrl();
                if (HOST.equals(url.getHost())) return false;          // stay inside the app
                try { startActivity(new Intent(Intent.ACTION_VIEW, url)); } catch (Exception ignored) {}
                return true;                                           // http, mailto, spotify… → system
            }
            @Override
            public void onPageFinished(WebView view, String url) {
                // hide the "add to home screen" hint and route file exports through the share sheet
                view.evaluateJavascript(BRIDGE_JS, null);
            }
        });
        web.setWebChromeClient(new WebChromeClient());                 // alert / confirm / prompt dialogs
        web.addJavascriptInterface(new Bridge(), "AndroidBridge");

        if (savedInstanceState == null) web.loadUrl(START);
        else web.restoreState(savedInstanceState);
    }

    private static final String BRIDGE_JS =
        "(function(){ if (window.__dbNative) return; window.__dbNative = 'android';" +
        " var st = document.createElement('style'); st.textContent = '#installnote{display:none !important}'; document.head.appendChild(st);" +
        " var origClick = HTMLAnchorElement.prototype.click;" +
        " HTMLAnchorElement.prototype.click = function(){ var a = this;" +
        "   if (a.download && a.href && a.href.indexOf('blob:') === 0) {" +
        "     fetch(a.href).then(function(r){ return r.blob(); }).then(function(b){ var fr = new FileReader();" +
        "       fr.onload = function(){ AndroidBridge.saveFile(a.download || 'drawing-board-backup.json', String(fr.result).split(',')[1]); };" +
        "       fr.readAsDataURL(b); }); return; }" +
        "   return origClick.call(a); };" +
        "})();";

    /** Receives the exported backup from the page and offers it through Android's share sheet. */
    private class Bridge {
        @JavascriptInterface
        public void saveFile(String name, String base64) {
            try {
                File dir = new File(getCacheDir(), "exports"); dir.mkdirs();
                File f = new File(dir, name.replaceAll("[^A-Za-z0-9._-]", "_"));
                try (FileOutputStream out = new FileOutputStream(f)) { out.write(Base64.decode(base64, Base64.DEFAULT)); }
                Uri uri = FileProvider.getUriForFile(MainActivity.this, getPackageName() + ".files", f);
                Intent share = new Intent(Intent.ACTION_SEND).setType("application/json")
                        .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                runOnUiThread(() -> startActivity(Intent.createChooser(share, "Save your backup")));
            } catch (Exception ignored) {}
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        web.saveState(outState);
    }
}
