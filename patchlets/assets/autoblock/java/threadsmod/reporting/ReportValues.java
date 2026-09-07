package threadsmod.reporting;

import java.net.URI;
import java.util.Locale;

/** Shared validation and UTF-16-safe bounding for the reporting patchlet. */
final class ReportValues {
    static final int MAX_USERNAME = 64;
    static final int MAX_DISPLAY_NAME = 120;
    static final int MAX_PERMALINK = 300;
    static final int MAX_POST_CONTENT = 280;
    static final int MAX_NOTE = 400;
    static final int MAX_LANGUAGE = 32;
    static final int MAX_TIME_ZONE = 64;

    private ReportValues() {}

    static boolean isNumericId(String value) {
        if (value == null || value.length() < 4 || value.length() > 24) {
            return false;
        }
        if (value.charAt(0) < '1' || value.charAt(0) > '9') {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c < '0' || c > '9') {
                return false;
            }
        }
        return true;
    }

    static String normalizeUsername(String value) {
        String source = cleanText(value, MAX_USERNAME + 1).toLowerCase(Locale.US);
        while (source.startsWith("@")) {
            source = source.substring(1);
        }
        if (source.length() == 0 || source.length() > MAX_USERNAME) {
            return "";
        }
        for (int i = 0; i < source.length(); i++) {
            char c = source.charAt(i);
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                    || c == '_' || c == '.')) {
                return "";
            }
        }
        return source;
    }

    static String cleanText(String value, int maxUtf16Units) {
        if (value == null || maxUtf16Units <= 0) {
            return "";
        }
        StringBuilder clean = new StringBuilder(Math.min(value.length(), maxUtf16Units));
        for (int offset = 0; offset < value.length();) {
            int codePoint = value.codePointAt(offset);
            int inputWidth = Character.charCount(codePoint);
            offset += inputWidth;

            if (codePoint == 127 || (codePoint < 32 && codePoint != '\n'
                    && codePoint != '\r' && codePoint != '\t')) {
                continue;
            }
            if (codePoint >= Character.MIN_SURROGATE
                    && codePoint <= Character.MAX_SURROGATE) {
                continue;
            }
            int outputWidth = Character.charCount(codePoint);
            if (clean.length() + outputWidth > maxUtf16Units) {
                break;
            }
            clean.appendCodePoint(codePoint);
        }
        return clean.toString().trim();
    }

    static String cleanToken(String value, int maxLength) {
        String clean = cleanText(value, maxLength);
        for (int i = 0; i < clean.length(); i++) {
            char c = clean.charAt(i);
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                    || c == '_' || c == '-' || c == '.')) {
                return "";
            }
        }
        return clean;
    }

    static String httpsThreadsPermalink(String value, String expectedUsername) {
        String expected = normalizeUsername(expectedUsername);
        if (value == null || value.length() == 0 || value.length() > MAX_PERMALINK
                || expected.length() == 0) {
            return "";
        }
        String clean = cleanText(value, MAX_PERMALINK);
        if (!clean.equals(value)) {
            return "";
        }
        try {
            URI uri = new URI(clean);
            String scheme = uri.getScheme();
            String host = uri.getHost();
            if (!"https".equalsIgnoreCase(scheme) || host == null
                    || uri.isOpaque()
                    || uri.getUserInfo() != null
                    || uri.getPort() != -1
                    || uri.getRawQuery() != null
                    || uri.getRawFragment() != null
                    || uri.getRawPath() == null) {
                return "";
            }
            String normalizedHost = host.toLowerCase(Locale.US);
            if (!("www.threads.com".equals(normalizedHost)
                    || "www.threads.net".equals(normalizedHost))) {
                return "";
            }
            String authority = uri.getRawAuthority();
            if (authority == null
                    || !normalizedHost.equals(authority.toLowerCase(Locale.US))) {
                return "";
            }
            String path = uri.getRawPath();
            if (path.indexOf('%') >= 0 || !path.startsWith("/@")) {
                return "";
            }
            int postMarker = path.indexOf("/post/", 2);
            if (postMarker <= 2 || postMarker != path.lastIndexOf("/post/")) {
                return "";
            }
            String pathUsername = path.substring(2, postMarker);
            String shortcode = path.substring(postMarker + 6);
            if (!expected.equals(pathUsername) || shortcode.length() == 0) {
                return "";
            }
            for (int i = 0; i < shortcode.length(); i++) {
                char c = shortcode.charAt(i);
                if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                        || (c >= '0' && c <= '9') || c == '_' || c == '-')) {
                    return "";
                }
            }
            return "https://www.threads.com/@" + expected + "/post/" + shortcode;
        } catch (Throwable ignored) {
            return "";
        }
    }

    static boolean isPseudonym(String value) {
        if (value == null || value.length() != 29 || !value.startsWith("acct_")) {
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
}
