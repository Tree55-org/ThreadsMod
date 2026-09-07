package threadsmod.reporting;

/**
 * Closed activation-statistics payload.
 *
 * <p>This object exists so basic install counts and coarse device mix can be measured without
 * carrying any account identity. It accepts a fixed, bounded field set, restricts every text
 * value to one safe token charset so the serialized form never needs escaping, and emits exactly
 * one canonical key order. There is no field for a Threads viewer ID, target ID, username,
 * permalink, post text, token, or free text, so account data cannot reach the statistics
 * endpoint even by mistake.</p>
 */
final class InstallStatsPayload {
    static final int VERSION = 1;
    static final int MAX_PACKAGE = 128;
    static final int MAX_VERSION_NAME = 64;
    static final int MAX_DEVICE_TOKEN = 64;
    static final int MAX_ABI = 32;
    static final int MIN_SDK_INT = 1;
    static final int MAX_SDK_INT = 100;

    /** Canonical serialized key order; the harness pins this exact set. */
    static final String[] KEYS = new String[] {
            "v", "installId", "packageName", "versionName", "versionCode",
            "modBuild", "sdk", "manufacturer", "model", "abi", "lang", "tz", "sentAt"
    };

    private final String installId;
    private final String packageName;
    private final String versionName;
    private final long versionCode;
    private final int modBuild;
    private final int sdkInt;
    private final String manufacturer;
    private final String model;
    private final String abi;
    private final String language;
    private final String timeZone;
    private final long sentAt;

    private InstallStatsPayload(
            String installId,
            String packageName,
            String versionName,
            long versionCode,
            int modBuild,
            int sdkInt,
            String manufacturer,
            String model,
            String abi,
            String language,
            String timeZone,
            long sentAt) {
        this.installId = isInstallId(installId) ? installId : "";
        this.packageName = safeToken(packageName, MAX_PACKAGE);
        this.versionName = safeToken(versionName, MAX_VERSION_NAME);
        this.versionCode = versionCode;
        this.modBuild = modBuild;
        this.sdkInt = sdkInt;
        this.manufacturer = safeToken(manufacturer, MAX_DEVICE_TOKEN);
        this.model = safeToken(model, MAX_DEVICE_TOKEN);
        this.abi = safeToken(abi, MAX_ABI);
        this.language = safeToken(language, ReportValues.MAX_LANGUAGE);
        this.timeZone = safeToken(timeZone, ReportValues.MAX_TIME_ZONE);
        this.sentAt = sentAt;
    }

    static InstallStatsPayload create(
            String installId,
            String packageName,
            String versionName,
            long versionCode,
            int modBuild,
            int sdkInt,
            String manufacturer,
            String model,
            String abi,
            String language,
            String timeZone,
            long sentAt) {
        return new InstallStatsPayload(
                installId, packageName, versionName, versionCode, modBuild, sdkInt,
                manufacturer, model, abi, language, timeZone, sentAt);
    }

    /**
     * A stable per-installation identifier. It is domain separated from the reporting
     * pseudonym and derived without any account input, so the two can never be correlated.
     */
    static boolean isInstallId(String value) {
        if (value == null || value.length() != 29 || !value.startsWith("inst_")) {
            return false;
        }
        for (int i = 5; i < value.length(); i++) {
            char c = value.charAt(i);
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
                return false;
            }
        }
        return true;
    }

    /**
     * Keeps only characters that are safe in a JSON string without escaping. Anything else
     * ends the token, so a hostile or unusual device string cannot inject structure.
     *
     * <p>The forward slash is in the set because every IANA time zone id outside UTC contains
     * one, and a tz field that drops it reports {@code AsiaBangkok}, which is not a time zone at
     * all. A slash needs no escaping in a JSON string, so admitting it costs nothing.</p>
     */
    static String safeToken(String value, int maxUtf16Units) {
        if (value == null || maxUtf16Units <= 0) {
            return "";
        }
        StringBuilder clean = new StringBuilder(Math.min(value.length(), maxUtf16Units));
        for (int i = 0; i < value.length() && clean.length() < maxUtf16Units; i++) {
            char c = value.charAt(i);
            boolean safe = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9')
                    || c == '.' || c == '_' || c == '-' || c == '+' || c == '/' || c == ' ';
            if (safe) {
                clean.append(c);
            }
        }
        int end = clean.length();
        while (end > 0 && clean.charAt(end - 1) == ' ') {
            end--;
        }
        int start = 0;
        while (start < end && clean.charAt(start) == ' ') {
            start++;
        }
        return clean.substring(start, end);
    }

    boolean isValid() {
        return installId.length() > 0
                && packageName.length() > 0
                && versionName.length() > 0
                && versionCode > 0L
                && modBuild >= 1
                && sdkInt >= MIN_SDK_INT && sdkInt <= MAX_SDK_INT
                && sentAt > 0L;
    }

    String getInstallId() {
        return installId;
    }

    /** Canonical, escape-free serialization in the exact declared key order. */
    String toJson() {
        if (!isValid()) {
            return "";
        }
        StringBuilder out = new StringBuilder(256);
        out.append('{');
        appendNumber(out, "v", VERSION, true);
        appendText(out, "installId", installId, false);
        appendText(out, "packageName", packageName, false);
        appendText(out, "versionName", versionName, false);
        appendNumber(out, "versionCode", versionCode, false);
        appendNumber(out, "modBuild", modBuild, false);
        appendNumber(out, "sdk", sdkInt, false);
        appendText(out, "manufacturer", manufacturer, false);
        appendText(out, "model", model, false);
        appendText(out, "abi", abi, false);
        appendText(out, "lang", language, false);
        appendText(out, "tz", timeZone, false);
        appendNumber(out, "sentAt", sentAt, false);
        out.append('}');
        return out.toString();
    }

    private static void appendText(
            StringBuilder out, String key, String value, boolean first) {
        if (!first) {
            out.append(',');
        }
        out.append('"').append(key).append("\":\"").append(value).append('"');
    }

    private static void appendNumber(
            StringBuilder out, String key, long value, boolean first) {
        if (!first) {
            out.append(',');
        }
        out.append('"').append(key).append("\":").append(value);
    }
}
