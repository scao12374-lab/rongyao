package cn.personacouncil.app;

import android.app.Activity;
import android.os.Bundle;
import android.net.Uri;
import android.graphics.Color;
import android.view.View;
import android.view.WindowInsets;
import android.widget.LinearLayout;
import android.widget.EditText;
import android.widget.Button;
import android.widget.TextView;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.CookieManager;

/** HTTPS cloud client. No model keys, native JS bridge, or file access. */
public class MainActivity extends Activity {
    private WebView web;
    private String origin = "";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(16,21,30));
        root.setPadding(16,16,16,0);
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            root.setOnApplyWindowInsetsListener((v, insets) -> {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
                v.setPadding(16 + bars.left, 16 + bars.top, 16 + bars.right, bars.bottom);
                return insets;
            });
        }
        TextView title = new TextView(this);
        title.setText("人格议事厅 · 个人云端");
        title.setTextColor(Color.WHITE);
        title.setTextSize(20);
        root.addView(title);
        EditText url = new EditText(this);
        url.setSingleLine(true);
        url.setTextColor(Color.WHITE);
        url.setHintTextColor(Color.LTGRAY);
        url.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI);
        url.setHint("https://你的服务域名");
        url.setText(getPreferences(MODE_PRIVATE).getString("server", ""));
        root.addView(url);
        Button connect = new Button(this);
        connect.setText("连接云端服务");
        root.addView(connect);
        TextView error = new TextView(this);
        error.setTextColor(Color.rgb(255,187,169));
        root.addView(error);
        web = new WebView(this);
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(false);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setSupportMultipleWindows(false);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, false);
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                return !sameOrigin(req.getUrl());
            }
            @Override public void onReceivedSslError(WebView view, android.webkit.SslErrorHandler handler, android.net.http.SslError sslError) {
                handler.cancel();
                error.setText("证书无效，请检查服务器 HTTPS 配置。");
            }
        });
        root.addView(web, new LinearLayout.LayoutParams(-1, 0, 1));
        setContentView(root);
        connect.setOnClickListener(v -> {
            Uri parsed = Uri.parse(url.getText().toString().trim());
            if (!"https".equals(parsed.getScheme()) || parsed.getHost() == null || parsed.getUserInfo() != null
                    || parsed.getQuery() != null || parsed.getFragment() != null || !(parsed.getPath() == null || parsed.getPath().isEmpty() || "/".equals(parsed.getPath()))) {
                error.setText("请输入完整 HTTPS 服务地址，不包含路径、账号、参数或片段。");
                return;
            }
            origin = "https://" + parsed.getEncodedAuthority();
            getPreferences(MODE_PRIVATE).edit().putString("server", origin).apply();
            error.setText("");
            web.loadUrl(origin + "/");
        });
        if (!url.getText().toString().isEmpty()) connect.performClick();
    }

    private boolean sameOrigin(Uri uri) {
        Uri allowed = Uri.parse(origin);
        return "https".equals(uri.getScheme()) && uri.getHost() != null
            && uri.getHost().equalsIgnoreCase(allowed.getHost()) && uri.getPort() == allowed.getPort();
    }

    @Override public void onBackPressed() {
        if (web.canGoBack()) web.goBack(); else super.onBackPressed();
    }
    @Override protected void onDestroy() {
        web.destroy();
        super.onDestroy();
    }
}
