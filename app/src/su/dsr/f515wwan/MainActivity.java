package su.dsr.f515wwan;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * wwan-up.sh does all the real work (stage by stage, each stage checks its own
 * precondition before acting) - this screen just deploys it and runs it with different
 * argument sets. Nothing runs automatically: only on button press.
 */
public class MainActivity extends Activity {

    private static final String SPEEDTEST_URL = "https://internet.yandex.ru";

    private TextView log;
    private LinearLayout buttonsRow;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private boolean busy = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(24, 24, 24, 24);
        root.setBackgroundColor(Color.BLACK);

        TextView version = new TextView(this);
        version.setText("F515 WWAN " + versionName());
        version.setTextColor(Color.GRAY);
        version.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        root.addView(version);

        buttonsRow = new LinearLayout(this);
        buttonsRow.setOrientation(LinearLayout.HORIZONTAL);
        addRunButton("Проверка", "--check");
        addRunButton("Включить", "--system");
        addRunButton("Выключить", "--down");
        addUrlButton("Интернетометр", SPEEDTEST_URL);
        ScrollView buttonsScroll = new ScrollView(this);
        buttonsScroll.setHorizontalScrollBarEnabled(false);
        buttonsScroll.addView(buttonsRow);
        root.addView(buttonsScroll);

        log = new TextView(this);
        log.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        log.setTextColor(Color.WHITE);
        log.setTextIsSelectable(true);
        log.setGravity(Gravity.TOP);
        ScrollView sv = new ScrollView(this);
        sv.addView(log);
        root.addView(sv);

        setContentView(root);

        append("ready. adbd target " + Keeper.ADB_HOST + ":" + Keeper.ADB_PORT);
        append("ничего не запускается само - только по кнопке.");
        append("");
        append("Проверка      - только диагностика, ничего не меняет");
        append("Включить      - поднять модем/PPP и раздать интернет приложениям Android");
        append("Выключить     - остановить pppd");
        append("Интернетометр - открыть " + SPEEDTEST_URL + " (проверка интернета глазами)");
    }

    private void addRunButton(String text, final String args) {
        buttonsRow.addView(button(text, new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (busy) return;
                setBusy(true);
                append("");
                append("> " + (text.isEmpty() ? "wwan-up.sh" : text) + " ...");
                background(new Runnable() {
                    @Override
                    public void run() {
                        Keeper.run(MainActivity.this, args, new Keeper.Progress() {
                            @Override
                            public void onLine(final String line) {
                                post(line);
                            }
                        });
                        ui.post(new Runnable() {
                            @Override
                            public void run() {
                                setBusy(false);
                            }
                        });
                    }
                });
            }
        }));
    }

    /**
     * Открывает URL системным обработчиком ACTION_VIEW - тем же самым способом, которым
     * это уже проверено вручную (`am start -a android.intent.action.VIEW -d URL`), а не
     * через свой WebView: на этой прошивке уже есть готовый webview-просмотрщик, поднимать
     * второй смысла нет.
     */
    private void addUrlButton(String text, final String url) {
        buttonsRow.addView(button(text, new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
                } catch (Exception e) {
                    append("не удалось открыть " + url + ": " + e);
                }
            }
        }));
    }

    private void setBusy(boolean b) {
        busy = b;
        for (int i = 0; i < buttonsRow.getChildCount(); i++) {
            buttonsRow.getChildAt(i).setEnabled(!b);
        }
    }

    private String versionName() {
        try {
            return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "?";
        }
    }

    private Button button(String text, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(text);
        b.setOnClickListener(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, 0, dp(12), 0);
        b.setLayoutParams(lp);
        return b;
    }

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics());
    }

    private void background(Runnable r) {
        new Thread(r, "wwan-work").start();
    }

    private void post(final String text) {
        ui.post(new Runnable() {
            @Override
            public void run() {
                append(text);
            }
        });
    }

    private void append(String text) {
        log.append(text + "\n");
    }
}
