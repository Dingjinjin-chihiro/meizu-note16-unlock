package io.github.dingjinjin.meizufreezer;

import android.app.Activity;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Bundle;
import android.app.AlertDialog;
import android.webkit.JsResult;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * 魅族冻结助手（WebView 版）
 *
 * 界面在 assets/index.html（HTML/CSS/JS），native 只提供能力：
 *   listApps / setFrozen / batch / applyList / exportFrozen
 *
 * 冻结: pm disable-user --user 0 <pkg>
 * 解冻: pm enable <pkg>
 *
 * 只保留 4 个绝对不可冻结项（冻掉手机就没法操作），其余不做任何限制。
 */
public class MainActivity extends Activity {

    private static final String SELF = "io.github.dingjinjin.meizufreezer";
    private static final Set<String> SAFE = new HashSet<>(Arrays.asList(
            "com.android.systemui",
            "com.meizu.flyme.launcher",
            "com.sohu.inputmethod.sogou.meizu",
            SELF
    ));

    private WebView web;
    private android.content.SharedPreferences prefs;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(Color.parseColor("#0f1115"));
        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#0f1115"));
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(true);
        web.setFitsSystemWindows(true);
        web.setVerticalScrollBarEnabled(false);
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onJsConfirm(WebView v, String url, String msg, final JsResult res) {
                new AlertDialog.Builder(MainActivity.this)
                        .setTitle("请确认")
                        .setMessage(msg)
                        .setPositiveButton("确定", (d, w) -> res.confirm())
                        .setNegativeButton("取消", (d, w) -> res.cancel())
                        .setCancelable(false)
                        .show();
                return true;
            }
        });
        web.addJavascriptInterface(new Bridge(), "Native");
        final android.widget.FrameLayout root = new android.widget.FrameLayout(this);
        root.addView(web, new android.widget.FrameLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.MATCH_PARENT));
        setContentView(root);
        root.post(new Runnable() {
            public void run() {
                int top = 0, bottom = 0;
                try {
                    android.view.WindowInsets ins = root.getRootWindowInsets();
                    if (ins != null) {
                        top = ins.getSystemWindowInsetTop();
                        bottom = ins.getSystemWindowInsetBottom();
                    }
                } catch (Throwable ignored) {}
                if (top <= 0) top = (int) (getResources().getDisplayMetrics().density * 32);
                web.setPadding(0, top, 0, bottom);
            }
        });
        prefs = getSharedPreferences(AutoFreezeService.PREF, MODE_PRIVATE);
        try {
            if (prefs.getBoolean("auto_enabled", false)) {
                startForegroundService(new android.content.Intent(this, AutoFreezeService.class));
                android.util.Log.i("AutoFreeze", "autostart requested");
            }
        } catch (Throwable t) {
            android.util.Log.e("AutoFreeze", "autostart failed: " + t);
        }
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            try { requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"}, 99); }
            catch (Throwable ignored) {}
        }
        web.loadUrl("file:///android_asset/index.html");
    }

    private String su(String cmd) {
        try {
            Process p = Runtime.getRuntime().exec(new String[]{"su", "-c", cmd});
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            StringBuilder sb = new StringBuilder();
            String line;
            int lines = 0;
            while ((line = r.readLine()) != null && lines < 200) { sb.append(line).append('\n'); lines++; }
            p.waitFor();
            return sb.toString();
        } catch (Exception e) {
            return "ERR:" + e.getMessage();
        }
    }

    private boolean isFrozen(String pkg) {
        int st = getPackageManager().getApplicationEnabledSetting(pkg);
        return st == PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                || st == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER
                || st == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED;
    }

    public class Bridge {

        @JavascriptInterface
        public String listApps() {
            try {
                PackageManager pm = getPackageManager();
                JSONArray arr = new JSONArray();
                List<Object[]> tmp = new ArrayList<>();
                for (ApplicationInfo ai : pm.getInstalledApplications(0)) {
                    if (SELF.equals(ai.packageName)) continue;
                    String label;
                    try { label = pm.getApplicationLabel(ai).toString(); }
                    catch (Exception e) { label = ai.packageName; }
                    boolean system = (ai.flags & ApplicationInfo.FLAG_SYSTEM) != 0;
                    boolean frozen = isFrozen(ai.packageName);
                    long apkSize = 0;
                    try { apkSize = new java.io.File(ai.sourceDir).length(); } catch (Throwable ignored) {}
                    tmp.add(new Object[]{label, ai.packageName, system, frozen, apkSize});
                }
                Collections.sort(tmp, new Comparator<Object[]>() {
                    public int compare(Object[] a, Object[] b) {
                        return ((String) a[0]).compareToIgnoreCase((String) b[0]);
                    }
                });
                for (Object[] o : tmp) {
                    JSONObject jo = new JSONObject();
                    jo.put("l", o[0]);
                    jo.put("p", o[1]);
                    jo.put("s", o[2]);
                    jo.put("f", o[3]);
                    jo.put("z", o[4]);
                    arr.put(jo);
                }
                return arr.toString();
            } catch (Exception e) {
                return "[]";
            }
        }

        @JavascriptInterface
        public String setFrozen(String pkg, boolean freeze) {
            if (pkg == null || pkg.isEmpty() || SAFE.contains(pkg)) return "0";
            String out = su(freeze
                    ? "pm disable-user --user 0 " + pkg
                    : "pm enable " + pkg);
            boolean ok = freeze ? out.contains("disabled") : out.contains("enabled");
            return ok ? "1" : "0";
        }

        @JavascriptInterface
        public String batch(String pkgsJson, boolean freeze) {
            try {
                JSONArray arr = new JSONArray(pkgsJson);
                StringBuilder sb = new StringBuilder();
                int n = 0;
                for (int i = 0; i < arr.length(); i++) {
                    String pkg = arr.getString(i);
                    if (pkg == null || pkg.isEmpty() || SAFE.contains(pkg)) continue;
                    sb.append(freeze
                            ? "pm disable-user --user 0 " + pkg
                            : "pm enable " + pkg).append("; ");
                    n++;
                }
                if (n == 0) return "0";
                su(sb.toString());
                return String.valueOf(n);
            } catch (Exception e) {
                return "0";
            }
        }

        @JavascriptInterface
        public String applyList(String text) {
            int ok = 0, skip = 0;
            try {
                StringBuilder sb = new StringBuilder();
                Set<String> installed = new HashSet<>();
                for (ApplicationInfo ai : getPackageManager().getInstalledApplications(0)) {
                    installed.add(ai.packageName);
                }
                for (String raw : text.split("\n")) {
                    String line = raw.trim();
                    if (line.isEmpty() || line.startsWith("#")) continue;
                    String pkg = line.split("\\s+")[0];
                    if (!pkg.matches("[a-zA-Z][\\w.]*")) { skip++; continue; }
                    if (SAFE.contains(pkg) || !installed.contains(pkg) || isFrozen(pkg)) { skip++; continue; }
                    sb.append("pm disable-user --user 0 ").append(pkg).append("; ");
                    ok++;
                }
                if (ok > 0) su(sb.toString());
                JSONObject r = new JSONObject();
                r.put("ok", ok);
                r.put("skip", skip);
                return r.toString();
            } catch (Exception e) {
                return "{\"ok\":0,\"skip\":0}";
            }
        }

        private final java.util.HashMap<String, String> iconCache = new java.util.HashMap<>();

        @JavascriptInterface
        public String iconFor(String pkg) {
            try {
                String cached = iconCache.get(pkg);
                if (cached != null) return cached;
                android.graphics.drawable.Drawable d = getPackageManager().getApplicationIcon(pkg);
                int size = (int) (getResources().getDisplayMetrics().density * 44);
                android.graphics.Bitmap bmp = android.graphics.Bitmap.createBitmap(
                        size, size, android.graphics.Bitmap.Config.ARGB_8888);
                android.graphics.Canvas c = new android.graphics.Canvas(bmp);
                d.setBounds(0, 0, size, size);
                d.draw(c);
                java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
                bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 88, bos);
                String uri = "data:image/png;base64," + android.util.Base64.encodeToString(
                        bos.toByteArray(), android.util.Base64.NO_WRAP);
                iconCache.put(pkg, uri);
                return uri;
            } catch (Throwable t) {
                return "";
            }
        }

        @JavascriptInterface
        public String appDetail(String pkg) {
            try {
                PackageManager pm = getPackageManager();
                ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
                android.content.pm.PackageInfo pi = pm.getPackageInfo(pkg, 0);
                JSONObject o = new JSONObject();
                o.put("pkg", pkg);
                o.put("label", pm.getApplicationLabel(ai).toString());
                o.put("uid", ai.uid);
                o.put("ver", pi.versionName == null ? "?" : pi.versionName);
                o.put("vcode", pi.getLongVersionCode());
                o.put("target", ai.targetSdkVersion);
                o.put("min", ai.minSdkVersion);
                o.put("apk", ai.sourceDir);
                long apkSize = 0;
                try { apkSize = new java.io.File(ai.sourceDir).length(); } catch (Throwable ignored) {}
                o.put("apkSize", apkSize);
                o.put("sys", (ai.flags & ApplicationInfo.FLAG_SYSTEM) != 0);
                o.put("frozen", isFrozen(pkg));
                try { o.put("install", pi.firstInstallTime); } catch (Throwable t) {}
                try { o.put("update", pi.lastUpdateTime); } catch (Throwable t) {}

                boolean running = false;
                try {
                    android.app.ActivityManager am = (android.app.ActivityManager)
                            getSystemService(ACTIVITY_SERVICE);
                    for (android.app.ActivityManager.RunningAppProcessInfo rp : am.getRunningAppProcesses()) {
                        if (rp.processName.equals(pkg) || rp.processName.startsWith(pkg + ":")) {
                            running = true;
                            o.put("pid", rp.pid);
                            break;
                        }
                    }
                } catch (Throwable ignored) {}
                o.put("running", running);

                // 数据目录大小（root du，详情页才取）
                long dataKb = -1;
                try {
                    String out = su("du -sk " + ai.dataDir + " 2>/dev/null").trim();
                    if (!out.isEmpty()) {
                        String tok = out.split("\\s+")[0];
                        if (tok.matches("\\d+")) dataKb = Long.parseLong(tok);
                    }
                } catch (Throwable ignored) {}
                o.put("dataKb", dataKb);

                String launcher = "?"; 
                try {
                    android.content.Intent it = pm.getLaunchIntentForPackage(pkg);
                    launcher = it == null ? "无启动界面" : "可启动";
                } catch (Throwable ignored) {}
                o.put("launch", launcher);
                return o.toString();
            } catch (Exception e) {
                return "{}";
            }
        }

        @JavascriptInterface
        public String launchApp(String pkg) {
            try {
                android.content.Intent it = getPackageManager().getLaunchIntentForPackage(pkg);
                if (it == null) return "0";
                it.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(it);
                return "1";
            } catch (Exception e) {
                return "0";
            }
        }

        @JavascriptInterface
        public String autoStatus() {
            try {
                boolean en = prefs.getBoolean("auto_enabled", false);
                String targets = prefs.getString("auto_targets", "[]");
                JSONObject o = new JSONObject();
                o.put("enabled", en);
                o.put("targets", new JSONArray(targets));
                o.put("last", prefs.getLong("auto_last", 0));
                o.put("lastCount", prefs.getInt("auto_last_count", 0));
                return o.toString();
            } catch (Exception e) {
                return "{\"enabled\":false,\"targets\":[]}";
            }
        }

        @JavascriptInterface
        public String autoEnable(boolean on) {
            try {
                prefs.edit().putBoolean("auto_enabled", on).apply();
                android.content.Intent it = new android.content.Intent(
                        MainActivity.this, AutoFreezeService.class);
                if (on) startForegroundService(it);
                else stopService(it);
                return "1";
            } catch (Throwable t) {
                return "0";
            }
        }

        @JavascriptInterface
        public String autoRunNow() {
            try {
                AutoFreezeService.runNow(MainActivity.this);
                return "1";
            } catch (Throwable t) {
                return "0";
            }
        }

        @JavascriptInterface
        public String autoSetTargets(String json) {
            try {
                new JSONArray(json);
                prefs.edit().putString("auto_targets", json).apply();
                return "1";
            } catch (Throwable t) {
                return "0";
            }
        }

        @JavascriptInterface
        public String exportFrozen() {
            try {
                StringBuilder sb = new StringBuilder();
                sb.append("# 魅族冻结助手 导出\n# ").append(new java.util.Date()).append("\n\n");
                List<String> pkgs = new ArrayList<>();
                for (ApplicationInfo ai : getPackageManager().getInstalledApplications(0)) {
                    if (isFrozen(ai.packageName)) pkgs.add(ai.packageName);
                }
                Collections.sort(pkgs);
                for (String p : pkgs) sb.append(p).append('\n');
                File dir = getExternalFilesDir(null);
                File f = new File(dir, "frozen-" + System.currentTimeMillis() + ".txt");
                FileOutputStream fos = new FileOutputStream(f);
                OutputStreamWriter w = new OutputStreamWriter(fos, "UTF-8");
                w.write(sb.toString());
                w.close();
                return f.getAbsolutePath();
            } catch (Exception e) {
                return "ERR:" + e.getMessage();
            }
        }
    }
}