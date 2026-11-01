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

    /** 默认加锁清单：核心系统组件 + 不该冻结的功能组件（恢复默认时使用） */
    private static final String[] DEFAULT_LOCK = {
            "com.android.avatarpicker",
            "com.android.backupconfirm",
            "com.android.bips",
            "com.android.bluetooth",
            "com.android.bluetoothmidiservice",
            "com.android.bookmarkprovider",
            "com.android.calllogbackup",
            "com.android.carrierdefaultapp",
            "com.android.cellbroadcastreceiver",
            "com.android.cellbroadcastreceiver.module",
            "com.android.cellbroadcastservice",
            "com.android.companiondevicemanager",
            "com.android.compos.payload",
            "com.android.customization.themes",
            "com.android.devicediagnostics",
            "com.android.devicelockcontroller",
            "com.android.dialer",
            "com.android.dreams.basic",
            "com.android.dreams.phototable",
            "com.android.federatedcompute.services",
            "com.android.health.connect.backuprestore",
            "com.android.hotspot2.osulogin",
            "com.android.htmlviewer",
            "com.android.managedprovisioning",
            "com.android.microdroid.empty_payload",
            "com.android.mms",
            "com.android.musicfx",
            "com.android.networkstack",
            "com.android.networkstack.tethering",
            "com.android.nfc",
            "com.android.ondevicepersonalization.services",
            "com.android.ons",
            "com.android.permissioncontroller",
            "com.android.phone",
            "com.android.printspooler",
            "com.android.providers.contactkeys",
            "com.android.providers.partnerbookmarks",
            "com.android.providers.settings",
            "com.android.providers.telephony",
            "com.android.safetycenter.resources",
            "com.android.server.deviceconfig.resources",
            "com.android.server.telecom",
            "com.android.settings",
            "com.android.sharedstoragebackup",
            "com.android.shell",
            "com.android.simappdialog",
            "com.android.smspush",
            "com.android.stk",
            "com.android.systemui",
            "com.android.systemui.accessibility.accessibilitymenu",
            "com.android.uwb.resources",
            "com.android.virtualmachine.res",
            "com.android.wallpaper.livepicker",
            "com.android.wallpaperbackup",
            "com.android.wallpapercropper",
            "com.android.webview",
            "com.flyme.secureservice",
            "com.google.android.marvin.talkback",
            "com.google.android.webview",
            "com.ibimuyu.lockscreen",
            "com.meizu.customizecenter",
            "com.meizu.earphone",
            "com.meizu.ems",
            "com.meizu.flyme.launcher",
            "com.meizu.mznfcpay",
            "com.meizu.net.nativelockscreen",
            "com.meizu.wallpapersetting",
            "com.sohu.inputmethod.sogou.meizu",
            "com.sprd.omacp",
            "com.sprd.powersavemodelauncher",
            "com.unionpay.tsmservice"
    };


    /** 默认冻结清单：初始精简后的系统应用集合（恢复默认时按此还原系统应用状态） */
    private static final String[] DEFAULT_FROZEN = {
            "com.android.adservices.api",
            "com.android.egg",
            "com.android.healthconnect.controller",
            "com.android.traceur",
            "com.flyme.ability",
            "com.flyme.agentruntime",
            "com.flyme.ai.taskagent",
            "com.flyme.alivewallpaper",
            "com.flyme.callagent",
            "com.flyme.intelliLife",
            "com.flyme.linkpc",
            "com.flyme.linkUnion",
            "com.flyme.meizu.store",
            "com.flyme.scanner",
            "com.flyme.videoclips",
            "com.flyme.virtualdevice",
            "com.flyme.wordwallpaper.stroke",
            "com.google.android.apps.docs",
            "com.google.android.apps.docs.editors.sheets",
            "com.google.android.apps.photos",
            "com.google.android.apps.photosgo",
            "com.google.android.apps.translate",
            "com.google.android.apps.walletnfcrel",
            "com.google.android.deskclock",
            "com.google.android.gm",
            "com.google.android.googlequicksearchbox",
            "com.google.ar.lens",
            "com.meizu.account",
            "com.meizu.account.pay",
            "com.meizu.activeviewlivewallpaper",
            "com.meizu.alphame",
            "com.meizu.assistant",
            "com.meizu.cloud",
            "com.meizu.commdiagnostic",
            "com.meizu.datamigration",
            "com.meizu.dataservice",
            "com.meizu.feedback",
            "com.meizu.flyme.agentstore",
            "com.meizu.flyme.directservice",
            "com.meizu.flyme.find",
            "com.meizu.flyme.flymebbs",
            "com.meizu.flyme.gamecenter",
            "com.meizu.flyme.sdkstage",
            "com.meizu.flyme.service.find",
            "com.meizu.flyme.toolbox",
            "com.meizu.flyme.update",
            "com.meizu.flyme.weather",
            "com.meizu.gamecenter.service",
            "com.meizu.hotapp",
            "com.meizu.mcare",
            "com.meizu.media.music",
            "com.meizu.media.reader",
            "com.meizu.media.video",
            "com.meizu.meizuiot",
            "com.meizu.mstore",
            "com.meizu.mzbasestationsafe",
            "com.meizu.net.pedometer",
            "com.meizu.net.search",
            "com.meizu.picker",
            "com.meizu.pps",
            "com.meizu.remotecooperation",
            "com.meizu.smarthome",
            "com.meizu.suggestion",
            "com.meizu.voiceassistant",
            "com.sprd.camta",
            "com.sprd.engineermode",
            "com.sprd.linkturbo",
            "com.sprd.logmanager",
            "com.sprd.uasetting",
            "com.sprd.validationtools",
            "com.unisoc.silent.reboot",
            "com.unisoc.soundtrigger",
            "com.unisoc.tui"
    };
    private boolean unlockedThisSession = false;

    private static String sha256(String s) {
        try {
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            byte[] d = md.digest(("mzf::" + s).getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder();
            for (byte b : d) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) { return ""; }
    }



    private void ensureDefaultProtected() {
        if (!prefs.contains("protected")) {
            JSONArray a = new JSONArray();
            for (String p : DEFAULT_LOCK) a.put(p);
            prefs.edit().putString("protected", a.toString()).apply();
        }
    }

    private boolean isProtectedPkg(String pkg) {
        try {
            JSONArray a = new JSONArray(prefs.getString("protected", "[]"));
            for (int i = 0; i < a.length(); i++) if (pkg.equals(a.optString(i))) return true;
        } catch (Throwable ignored) {}
        return false;
    }

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
        ensureDefaultProtected();
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
                android.util.Log.i("FreezerUI", "listApps called");
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
        public String createShortcut(String pkg, boolean freeze) {
            try {
                if (android.os.Build.VERSION.SDK_INT < 26) return "0";
                android.content.pm.ShortcutManager sm =
                        (android.content.pm.ShortcutManager) getSystemService(SHORTCUT_SERVICE);
                if (sm == null || !sm.isRequestPinShortcutSupported()) return "0";
                String label;
                try {
                    label = getPackageManager().getApplicationLabel(
                            getPackageManager().getApplicationInfo(pkg, 0)).toString();
                } catch (Throwable t) { label = pkg; }

                android.content.Intent it = new android.content.Intent(MainActivity.this, ShortcutActivity.class);
                it.setAction(android.content.Intent.ACTION_VIEW);
                it.putExtra("pkg", pkg);
                it.putExtra("freeze", freeze);

                android.content.pm.ShortcutInfo si =
                        new android.content.pm.ShortcutInfo.Builder(MainActivity.this,
                                "mzf_" + (freeze ? "f" : "u") + "_" + pkg)
                                .setShortLabel((freeze ? "冻结 " : "解冻 ") + label)
                                .setLongLabel((freeze ? "冻结 " : "解冻 ") + label)
                                .setIcon(android.graphics.drawable.Icon.createWithResource(
                                        MainActivity.this, android.R.drawable.ic_lock_lock))
                                .setIntent(it)
                                .build();
                return sm.requestPinShortcut(si, null) ? "1" : "0";
            } catch (Throwable t) {
                return "0";
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
        public String protectStatus() {
            try {
                android.util.Log.i("FreezerUI", "protectStatus called");
                JSONObject o = new JSONObject();
                o.put("protected", new JSONArray(prefs.getString("protected", "[]")));
                JSONArray def = new JSONArray();
                for (String p : DEFAULT_LOCK) def.put(p);
                o.put("defaults", def);
                o.put("defaultFrozen", DEFAULT_FROZEN.length);
                return o.toString();
            } catch (Exception e) {
                return "{\"protected\":[],\"defaults\":[]}";
            }
        }

        /** 一键恢复初始状态：加锁清单 + 系统应用冻结状态（第三方应用不动） */
        @JavascriptInterface
        public String resetDefaults() {
            try {
                PackageManager pm = getPackageManager();

                // 1) 加锁清单 = 默认清单 + 保留用户自定义的非系统应用
                JSONArray old = new JSONArray(prefs.getString("protected", "[]"));
                JSONArray locks = new JSONArray();
                HashSet<String> seen = new HashSet<>();
                for (int i = 0; i < old.length(); i++) {
                    String p = old.optString(i);
                    if (p.isEmpty() || seen.contains(p)) continue;
                    boolean sys = true;
                    try {
                        sys = (pm.getApplicationInfo(p, 0).flags & ApplicationInfo.FLAG_SYSTEM) != 0;
                    } catch (Throwable ignored) {}
                    if (!sys) { locks.put(p); seen.add(p); }
                }
                for (String p : DEFAULT_LOCK) {
                    if (!seen.contains(p)) { locks.put(p); seen.add(p); }
                }
                prefs.edit().putString("protected", locks.toString()).apply();

                // 2) 系统应用冻结状态还原到 DEFAULT_FROZEN
                Set<String> want = new HashSet<>(Arrays.asList(DEFAULT_FROZEN));
                StringBuilder add = new StringBuilder();
                StringBuilder del = new StringBuilder();
                int nf = 0, nu = 0;
                for (ApplicationInfo ai : pm.getInstalledApplications(0)) {
                    if ((ai.flags & ApplicationInfo.FLAG_SYSTEM) == 0) continue; // 第三方不动
                    boolean frozen = isFrozen(ai.packageName);
                    boolean should = want.contains(ai.packageName);
                    if (should && !frozen) {
                        add.append("pm disable-user --user 0 ").append(ai.packageName).append("; ");
                        nf++;
                    } else if (!should && frozen) {
                        del.append("pm enable ").append(ai.packageName).append("; ");
                        nu++;
                    }
                }
                if (nf > 0) su(add.toString());
                if (nu > 0) su(del.toString());

                JSONObject r = new JSONObject();
                r.put("ok", 1);
                r.put("locks", locks.length());
                r.put("frozen", nf);
                r.put("unfrozen", nu);
                return r.toString();
            } catch (Throwable t) {
                return "{\"ok\":0}";
            }
        }

        /** 只恢复加锁清单 */
        @JavascriptInterface
        public String resetProtected() {
            try {
                JSONArray old = new JSONArray(prefs.getString("protected", "[]"));
                JSONArray out = new JSONArray();
                HashSet<String> seen = new HashSet<>();
                // 1) 保留用户添加的非系统应用
                PackageManager pm = getPackageManager();
                for (int i = 0; i < old.length(); i++) {
                    String p = old.optString(i);
                    if (p.isEmpty() || seen.contains(p)) continue;
                    boolean sys = true;
                    try { sys = (pm.getApplicationInfo(p, 0).flags
                            & ApplicationInfo.FLAG_SYSTEM) != 0; } catch (Throwable ignored) {}
                    if (!sys) { out.put(p); seen.add(p); }
                }
                // 2) 并入默认系统清单
                for (String p : DEFAULT_LOCK) {
                    if (!seen.contains(p)) { out.put(p); seen.add(p); }
                }
                prefs.edit().putString("protected", out.toString()).apply();
                return out.toString();
            } catch (Exception e) {
                return "[]";
            }
        }

        @JavascriptInterface
        public String setProtected(String json) {
            try {
                new JSONArray(json);
                prefs.edit().putString("protected", json).apply();
                return "1";
            } catch (Throwable t) { return "0"; }
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