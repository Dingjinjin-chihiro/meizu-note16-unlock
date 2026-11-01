package io.github.dingjinjin.meizufreezer;

import android.app.Activity;
import android.os.Bundle;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.InputStreamReader;

/**
 * 快捷方式入口：点桌面图标直接冻结 / 解冻某个应用，不打开主界面。
 *
 * Intent extra:
 *   pkg   —— 目标包名
 *   freeze —— true=冻结，false=解冻
 */
public class ShortcutActivity extends Activity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        String pkg = getIntent() == null ? null : getIntent().getStringExtra("pkg");
        boolean freeze = getIntent() == null || getIntent().getBooleanExtra("freeze", true);
        if (pkg == null || pkg.isEmpty()) {
            finish();
            return;
        }

        final String target = pkg;
        final boolean doFreeze = freeze;
        new Thread(() -> {
            String cmd = doFreeze
                    ? "pm disable-user --user 0 " + target
                    : "pm enable " + target;
            String out = su(cmd);
            boolean ok = doFreeze ? out.contains("disabled") : out.contains("enabled");
            runOnUiThread(() -> {
                Toast.makeText(ShortcutActivity.this,
                        (ok ? "已" : "失败：") + (doFreeze ? "冻结 " : "解冻 ") + target,
                        Toast.LENGTH_SHORT).show();
                finish();
            });
        }).start();
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
}
