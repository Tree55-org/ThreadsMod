package threadsmod.reporting;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.os.Build;

import java.io.OutputStream;
import java.net.CookieHandler;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.concurrent.atomic.AtomicBoolean;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import javax.net.ssl.HttpsURLConnection;

/**
 * One activation ping per installed build, sent on the first eligible foreground resume.
 *
 * <p>It exists so the project can count activations and see a coarse device mix. Its identifier is
 * derived from a local random secret with a fixed domain tag and no account input, so it is stable
 * per installation, is not the reporting pseudonym, and cannot be correlated to a Threads account.
 * The payload is the closed {@link InstallStatsPayload} field set; nothing else can be attached.
 * Every failure is silent and simply leaves the ping due again on a later foreground resume.</p>
 */
public final class InstallStats {
    static final String PREFS = "threadsmod_reporting";
    static final String INSTALL_SECRET_KEY = "stats_install_secret_v1";
    static final String SENT_BUILD_KEY = "stats_sent_build_v1";

    private static final int CONNECT_TIMEOUT_MS = 8000;
    private static final int READ_TIMEOUT_MS = 10000;
    private static final int MAX_REQUEST_BYTES = 4096;
    private static final int MAX_RESPONSE_BYTES = 8192;
    private static final AtomicBoolean RUNNING = new AtomicBoolean(false);

    private InstallStats() {}

    /**
     * Starts one bounded background delivery when this build has never been counted. Passive
     * blocking is always on and the Settings screen discloses this ping, so there is no opt-in
     * for the caller to confirm; this method performs no account or list work.
     */
    public static void maybeSend(final Context context) {
        if (context == null) {
            return;
        }
        final Context application = context.getApplicationContext();
        if (application == null) {
            return;
        }
        if (!RUNNING.compareAndSet(false, true)) {
            return;
        }
        boolean started = false;
        try {
            if (!isDue(application)) {
                return;
            }
            Thread worker = new Thread(new Runnable() {
                @Override
                public void run() {
                    try {
                        deliver(application);
                    } catch (Throwable ignored) {
                        // Statistics are best effort and never affect Block or report work.
                    } finally {
                        RUNNING.set(false);
                    }
                }
            }, "ThreadsModInstallStats");
            worker.setDaemon(true);
            worker.start();
            started = true;
        } catch (Throwable ignored) {
            // Fall through to release the guard below.
        } finally {
            if (!started) {
                RUNNING.set(false);
            }
        }
    }

    private static boolean isDue(Context context) {
        try {
            String marker = buildMarker(context);
            if (marker.length() == 0) {
                return false;
            }
            Map<String, ?> values = prefs(context).getAll();
            if (values == null) {
                return false;
            }
            Object raw = values.get(SENT_BUILD_KEY);
            if (raw == null) {
                return true;
            }
            return raw instanceof String && !marker.equals(raw);
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static void deliver(Context context) {
        String marker = buildMarker(context);
        InstallStatsPayload payload = payloadFor(context);
        if (marker.length() == 0 || payload == null || !payload.isValid()) {
            return;
        }
        if (post(payload)) {
            try {
                prefs(context).edit().putString(SENT_BUILD_KEY, marker).commit();
            } catch (Throwable ignored) {
                // An uncommitted marker only means the ping may repeat once later.
            }
        }
    }

    static InstallStatsPayload payloadFor(Context context) {
        try {
            PackageInfo info = context.getPackageManager()
                    .getPackageInfo(context.getPackageName(), 0);
            if (info == null) {
                return null;
            }
            long versionCode;
            try {
                versionCode = info.getLongVersionCode();
            } catch (Throwable belowApi28) {
                versionCode = info.versionCode;
            }
            return InstallStatsPayload.create(
                    installId(context),
                    context.getPackageName(),
                    info.versionName,
                    versionCode,
                    modBuild(),
                    Build.VERSION.SDK_INT,
                    Build.MANUFACTURER,
                    Build.MODEL,
                    primaryAbi(),
                    Locale.getDefault().toLanguageTag(),
                    TimeZone.getDefault().getID(),
                    System.currentTimeMillis());
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static int modBuild() {
        long build = threadsmod.update.UpdateController.CURRENT_MOD_BUILD;
        return build >= 1L && build <= Integer.MAX_VALUE ? (int) build : 1;
    }

    private static String primaryAbi() {
        try {
            String[] abis = Build.SUPPORTED_ABIS;
            return abis != null && abis.length > 0 ? abis[0] : "";
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static String buildMarker(Context context) {
        try {
            PackageInfo info = context.getPackageManager()
                    .getPackageInfo(context.getPackageName(), 0);
            if (info == null) {
                return "";
            }
            long versionCode;
            try {
                versionCode = info.getLongVersionCode();
            } catch (Throwable belowApi28) {
                versionCode = info.versionCode;
            }
            return versionCode + ":" + modBuild();
        } catch (Throwable ignored) {
            return "";
        }
    }

    /**
     * Stable per-installation identifier: HMAC of a local random secret over a fixed domain tag.
     * No account, device serial, or advertising identifier is an input.
     */
    static synchronized String installId(Context context) {
        try {
            SharedPreferences preferences = prefs(context);
            Map<String, ?> values = preferences.getAll();
            byte[] secret = null;
            if (values != null && values.get(INSTALL_SECRET_KEY) instanceof String) {
                secret = decode((String) values.get(INSTALL_SECRET_KEY));
            }
            if (secret == null) {
                secret = new byte[32];
                new SecureRandom().nextBytes(secret);
                if (!preferences.edit()
                        .putString(INSTALL_SECRET_KEY, encode(secret))
                        .commit()) {
                    return "";
                }
            }
            Mac hmac = Mac.getInstance("HmacSHA256");
            hmac.init(new SecretKeySpec(secret, "HmacSHA256"));
            byte[] digest = hmac.doFinal("install:v1".getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder(24);
            for (int i = 0; i < 12 && i < digest.length; i++) {
                hex.append(Character.forDigit((digest[i] >> 4) & 0xF, 16));
                hex.append(Character.forDigit(digest[i] & 0xF, 16));
            }
            return "inst_" + hex;
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static boolean post(InstallStatsPayload payload) {
        HttpsURLConnection connection = null;
        try {
            byte[] body = payload.toJson().getBytes(StandardCharsets.UTF_8);
            if (body.length == 0 || body.length > MAX_REQUEST_BYTES) {
                return false;
            }
            URL url = ReportEndpoint.statsUrl();
            synchronized (CookieHandler.class) {
                if (CookieHandler.getDefault() != null) {
                    return false;
                }
                connection = (HttpsURLConnection) url.openConnection();
            }
            connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
            connection.setReadTimeout(READ_TIMEOUT_MS);
            connection.setInstanceFollowRedirects(false);
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setUseCaches(false);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            connection.setRequestProperty("Accept", "application/json");
            connection.setRequestProperty("User-Agent", "ThreadsMod-CloneBlocker/1");
            connection.setFixedLengthStreamingMode(body.length);
            if (CookieHandler.getDefault() != null) {
                connection.disconnect();
                return false;
            }
            OutputStream output = connection.getOutputStream();
            try {
                output.write(body);
                output.flush();
            } finally {
                output.close();
            }
            int status = connection.getResponseCode();
            drain(connection);
            return status >= 200 && status <= 299;
        } catch (Throwable ignored) {
            return false;
        } finally {
            if (connection != null) {
                try {
                    connection.disconnect();
                } catch (Throwable ignored) {
                    // Nothing further to release.
                }
            }
        }
    }

    private static void drain(HttpsURLConnection connection) {
        try {
            java.io.InputStream input = connection.getResponseCode() >= 400
                    ? connection.getErrorStream() : connection.getInputStream();
            if (input == null) {
                return;
            }
            try {
                byte[] buffer = new byte[1024];
                int total = 0;
                while (total <= MAX_RESPONSE_BYTES && input.read(buffer) >= 0) {
                    total += buffer.length;
                }
            } finally {
                input.close();
            }
        } catch (Throwable ignored) {
            // The response body is never parsed; draining only frees the connection.
        }
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static String encode(byte[] value) {
        StringBuilder hex = new StringBuilder(value.length * 2);
        for (int i = 0; i < value.length; i++) {
            hex.append(Character.forDigit((value[i] >> 4) & 0xF, 16));
            hex.append(Character.forDigit(value[i] & 0xF, 16));
        }
        return hex.toString();
    }

    private static byte[] decode(String value) {
        if (value == null || value.length() != 64) {
            return null;
        }
        byte[] out = new byte[32];
        for (int i = 0; i < 32; i++) {
            int high = Character.digit(value.charAt(i * 2), 16);
            int low = Character.digit(value.charAt(i * 2 + 1), 16);
            if (high < 0 || low < 0) {
                return null;
            }
            out[i] = (byte) ((high << 4) | low);
        }
        return out;
    }
}
