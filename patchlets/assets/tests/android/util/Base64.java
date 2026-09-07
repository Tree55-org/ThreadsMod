package android.util;

/** Host-only Android Base64 seam for deterministic updater signature fixtures. */
public final class Base64 {
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int URL_SAFE = 8;

    private Base64() {}

    public static byte[] decode(String value, int flags) {
        return java.util.Base64.getUrlDecoder().decode(value);
    }

    public static String encodeToString(byte[] value, int flags) {
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }
}
