package io.github.dingjinjin.meizufreezer;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.os.IBinder;

import org.json.JSONArray;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.HashSet;
import java.util.Set;

/**
 * 自动冻结服务：屏幕熄灭时冻结「自动冻结清单」里的应用。
 *
 * - 只冻结清单内的应用，清单为空时什么都不做
 * - 正在前台使用的应用跳过（避免把用户正在用的冻掉）
 * - 常驻前台通知，可随时关掉
 */
public class AutoFreezeService extends Service {

    public static final String PREF = "freezer";
    private static final String CHANNEL = "autofreeze";
    private static final int NOTIF_ID = 1001;

    private static final String TAG = "AutoFreeze";
    private static final String ACTION_HEARTBEAT = "io.github.dingjinjin.meizufreezer.HEARTBEAT";
    private BroadcastReceiver receiver;
    private final android.os.Handler handler =
            new android.os.Handler(android.os.Looper.getMainLooper());
    private boolean lastInteractive = true;
    private long lastRunAt = 0;

    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            checkScreen();
            handler.postDelayed(this, 2000);
        }
    };

    /** 立即执行一次（供 UI 测试 / 手动触发） */
    public static void runNow(Context ctx) {
        Intent it = new Intent(ctx, AutoFreezeService.class);
        it.setAction("io.github.dingjinjin.meizufreezer.RUN_NOW");
        try { ctx.startForegroundService(it); } catch (Throwable ignored) {}
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
        startForeground(NOTIF_ID, buildNotification(0));

        receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                android.util.Log.i(TAG, "receive " + intent.getAction());
                if (Intent.ACTION_SCREEN_OFF.equals(intent.getAction())) {
                    runFreeze(false);
                }
            }
        };
        try { registerReceiver(receiver, new IntentFilter(Intent.ACTION_SCREEN_OFF)); }
        catch (Throwable t) { android.util.Log.w(TAG, "register receiver failed: " + t); }

        try {
            android.os.PowerManager pm =
                    (android.os.PowerManager) getSystemService(POWER_SERVICE);
            lastInteractive = pm != null && pm.isInteractive();
        } catch (Throwable ignored) {}
        handler.postDelayed(poll, 2000);
        scheduleHeartbeat();
        android.util.Log.i(TAG, "service created, interactive=" + lastInteractive);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? null : intent.getAction();
        if ("io.github.dingjinjin.meizufreezer.RUN_NOW".equals(action)) {
            android.util.Log.i(TAG, "manual run");
            runFreeze(true);
        } else if (ACTION_HEARTBEAT.equals(action)) {
            android.util.Log.i(TAG, "heartbeat");
            checkScreen();
        }
        scheduleHeartbeat();
        return START_STICKY;
    }

    /** 系统会在锁屏后冻结进程，用闹钟定期唤醒检查一次 */
    private void scheduleHeartbeat() {
        try {
            android.app.AlarmManager am =
                    (android.app.AlarmManager) getSystemService(ALARM_SERVICE);
            if (am == null) return;
            android.content.Intent it = new android.content.Intent(this, AutoFreezeService.class);
            it.setAction(ACTION_HEARTBEAT);
            int flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT;
            if (android.os.Build.VERSION.SDK_INT >= 23) flags |= android.app.PendingIntent.FLAG_IMMUTABLE;
            android.app.PendingIntent pi;
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                pi = android.app.PendingIntent.getForegroundService(this, 7, it, flags);
            } else {
                pi = android.app.PendingIntent.getService(this, 7, it, flags);
            }
            am.setAndAllowWhileIdle(android.app.AlarmManager.RTC_WAKEUP,
                    System.currentTimeMillis() + 60_000L, pi);
        } catch (Throwable t) {
            android.util.Log.w(TAG, "schedule failed: " + t);
        }
    }

    private void checkScreen() {
        try {
            android.os.PowerManager pm =
                    (android.os.PowerManager) getSystemService(POWER_SERVICE);
            boolean it = pm != null && pm.isInteractive();
            android.util.Log.i(TAG, "checkScreen interactive=" + it + " last=" + lastInteractive);
            if (!it) runFreeze(false);
            lastInteractive = it;
        } catch (Throwable ignored) {}
    }

    @Override
    public void onDestroy() {
        try { handler.removeCallbacks(poll); } catch (Throwable ignored) {}
        if (receiver != null) {
            try { unregisterReceiver(receiver); } catch (Throwable ignored) {}
            receiver = null;
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }

    // ---------------- 核心 ----------------

    private void runFreeze(boolean force) {
        new Thread(() -> {
            try {
                SharedPreferences p = getSharedPreferences(PREF, MODE_PRIVATE);
                boolean enabled = p.getBoolean("auto_enabled", false);
                long now = System.currentTimeMillis();
                if (!force && now - lastRunAt < 60_000L) {
                    android.util.Log.i(TAG, "runFreeze throttled");
                    return;
                }
                lastRunAt = now;
                android.util.Log.i(TAG, "runFreeze enabled=" + enabled + " force=" + force);
                if (!enabled && !force) return;
                String json = p.getString("auto_targets", "[]");
                JSONArray arr = new JSONArray(json);
                Set<String> fg = foregroundPackages();

                StringBuilder cmd = new StringBuilder();
                int n = 0;
                for (int i = 0; i < arr.length(); i++) {
                    String pkg = arr.optString(i, "");
                    if (pkg.isEmpty() || fg.contains(pkg)) continue;
                    cmd.append("pm disable-user --user 0 ").append(pkg).append("; ");
                    n++;
                }
                android.util.Log.i(TAG, "targets=" + arr.length() + " toFreeze=" + n + " fg=" + fg);
                if (n > 0) {
                    String out = su(cmd.toString());
                    android.util.Log.i(TAG, "su result: " + out.replace("\n", " | "));
                    p.edit().putLong("auto_last", System.currentTimeMillis())
                            .putInt("auto_last_count", n).apply();
                    NotificationManager nm = getSystemService(NotificationManager.class);
                    if (nm != null) nm.notify(NOTIF_ID, buildNotification(n));
                }
            } catch (Throwable ignored) {}
        }).start();
    }

    /** 当前在前台/可见的应用，跳过不冻 */
    private Set<String> foregroundPackages() {
        Set<String> out = new HashSet<>();
        try {
            android.app.ActivityManager am =
                    (android.app.ActivityManager) getSystemService(ACTIVITY_SERVICE);
            for (android.app.ActivityManager.RunningAppProcessInfo rp : am.getRunningAppProcesses()) {
                if (rp.importance <= android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE) {
                    out.add(rp.processName.split(":")[0]);
                }
            }
        } catch (Throwable ignored) {}
        return out;
    }

    private String su(String cmd) {
        try {
            Process p = Runtime.getRuntime().exec(new String[]{"su", "-c", cmd});
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) sb.append(line).append('\n');
            p.waitFor();
            return sb.toString();
        } catch (Exception e) {
            return "";
        }
    }

    // ---------------- 通知 ----------------

    private void createChannel() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm == null) return;
        NotificationChannel ch = new NotificationChannel(CHANNEL, "自动冻结",
                NotificationManager.IMPORTANCE_MIN);
        ch.setDescription("锁屏后自动冻结清单内的应用");
        nm.createNotificationChannel(ch);
    }

    private Notification buildNotification(int justFrozen) {
        Notification.Builder b;
        b = new Notification.Builder(this, CHANNEL);
        b.setContentTitle("自动冻结已开启");
        b.setContentText(justFrozen > 0
                ? ("刚刚冻结了 " + justFrozen + " 个应用")
                : "锁屏后自动冻结清单内的应用");
        b.setSmallIcon(android.R.drawable.ic_lock_lock);
        b.setOngoing(true);
        return b.build();
    }
}
