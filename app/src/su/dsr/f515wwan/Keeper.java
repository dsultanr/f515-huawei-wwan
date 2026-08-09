package su.dsr.f515wwan;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;

/**
 * Everything that needs root goes through here: connect to the local adbd (already root
 * on this build), deploy the wwan/ files and run wwan-up.sh with the requested stage set.
 * wwan-up.sh itself is idempotent and self-checking (see its own stage-by-stage checks),
 * so this class stays deliberately thin - it does not duplicate any of that logic, it
 * just makes sure the files it needs are on the device before running it.
 */
public class Keeper {

    static final String DIR = "/data/local/tmp/wwan";
    static final String SCRIPT = DIR + "/wwan-up.sh";
    static final String ADB_HOST = "127.0.0.1";
    static final int ADB_PORT = 5555;

    /** name in assets/, path on device, executable bit */
    private static final Object[][] FILES = {
            {"wwan-up.sh", "wwan-up.sh", Boolean.TRUE},
            {"dial.sh", "dial.sh", Boolean.TRUE},
            {"at.sh", "at.sh", Boolean.TRUE},
            {"huawei-modeswitch", "huawei-modeswitch", Boolean.TRUE},
            {"usbserialmerged2.ko", "usbserialmerged2.ko", Boolean.FALSE},
            {"ppp_async.ko", "ppp_async.ko", Boolean.FALSE},
    };

    private static final Object LOCK = new Object();

    public interface Progress {
        void onLine(String line);
    }

    /** Deploys wwan/ (skipping files already present with the right size) and runs a stage. */
    public static String run(Context ctx, String args, Progress progress) {
        synchronized (LOCK) {
            StringBuilder sb = new StringBuilder();
            AdbClient adb = null;
            try {
                // 130s: worst case inside wwan-up.sh is modeswitch reconnect wait (20s) +
                // network registration wait (30s) + dial timeout (45s) + margin.
                adb = connect(ctx, 130000);
                String uid = adb.shell("id -u").trim();
                line(progress, sb, "adb connected, uid=" + uid);
                if (!uid.startsWith("0")) {
                    line(progress, sb, "WARNING: adbd is not root, this will fail");
                }

                adb.shell("mkdir -p " + DIR);
                deployMissing(ctx, adb, progress, sb);

                String cmd = "sh " + SCRIPT + " " + args + " 2>&1";
                line(progress, sb, "--- " + cmd + " ---");
                String out = adb.shell(cmd);
                for (String l : out.split("\n")) line(progress, sb, l);
            } catch (Exception e) {
                line(progress, sb, "failed: " + e);
            } finally {
                if (adb != null) adb.close();
            }
            return sb.toString();
        }
    }

    private static AdbClient connect(Context ctx, int timeoutMs) throws Exception {
        return new AdbClient(ADB_HOST, ADB_PORT, asset(ctx, "adbkey"), asset(ctx, "adbkey.pub"), timeoutMs);
    }

    /**
     * Pushes only files that are missing or the wrong size (idempotent: pressing any
     * button again after the first run does not re-transfer ~800 KB every time).
     * Uses base64 chunks over the shell channel rather than the sync protocol, since the
     * shell() helper already exists and is proven to work - large payloads are just split
     * into pieces small enough that no single adb message approaches AdbClient's MAXDATA.
     */
    private static void deployMissing(Context ctx, AdbClient adb, Progress progress, StringBuilder sb)
            throws Exception {
        for (Object[] f : FILES) {
            String assetName = (String) f[0];
            String remote = DIR + "/" + f[1];
            boolean exec = (Boolean) f[2];

            byte[] data = asset(ctx, assetName);
            String remoteSize = adb.shell("stat -c%s " + remote + " 2>/dev/null || echo 0").trim();
            if (String.valueOf(data.length).equals(remoteSize)) {
                line(progress, sb, "  " + assetName + ": уже на месте (" + data.length + " Б)");
                continue;
            }

            line(progress, sb, "  " + assetName + ": заливаю (" + data.length + " Б)...");
            pushFile(adb, data, remote);

            String newSize = adb.shell("stat -c%s " + remote + " 2>/dev/null || echo -1").trim();
            if (!String.valueOf(data.length).equals(newSize)) {
                throw new java.io.IOException(assetName + ": после заливки размер " + newSize
                        + ", ожидался " + data.length);
            }
            if (exec) adb.shell("chmod 755 " + remote);
            line(progress, sb, "  " + assetName + ": ok");
        }
    }

    private static void pushFile(AdbClient adb, byte[] data, String remote) throws Exception {
        String b64 = android.util.Base64.encodeToString(data, android.util.Base64.NO_WRAP);
        String tmp = remote + ".b64";
        adb.shell("rm -f " + tmp);
        // ~48000 base64 chars/chunk keeps each adb shell command comfortably under any
        // adbd service-string limit while still needing only ~20 round trips per MB.
        int chunk = 48000;
        for (int i = 0; i < b64.length(); i += chunk) {
            String part = b64.substring(i, Math.min(b64.length(), i + chunk));
            adb.shell("echo '" + part + "' >> " + tmp);
        }
        String out = adb.shell("base64 -d " + tmp + " > " + remote + " && rm -f " + tmp + " && echo ok").trim();
        if (!out.contains("ok")) {
            throw new java.io.IOException("base64 -d не сработал: " + out);
        }
    }

    private static byte[] asset(Context ctx, String name) throws Exception {
        InputStream is = ctx.getAssets().open(name);
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = is.read(buf)) > 0) bos.write(buf, 0, n);
            return bos.toByteArray();
        } finally {
            is.close();
        }
    }

    private static void line(Progress progress, StringBuilder sb, String text) {
        sb.append(text).append('\n');
        if (progress != null) progress.onLine(text);
    }
}
