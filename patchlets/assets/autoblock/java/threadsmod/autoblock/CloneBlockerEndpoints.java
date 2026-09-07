package threadsmod.autoblock;

import java.net.URL;

/**
 * Static, ISP-safe Clone Blocker endpoint allowlist.
 *
 * The ISP-blocked legacy origin is intentionally absent. Signed v3 blocklist
 * reads (the signed root manifest plus the content-addressed group tables and
 * chunks it names) may fail over only between these public mirrors, and every
 * object name is proven against a closed grammar before it may touch a URL.
 * The separately consented reporting patchlet owns its own exact write
 * allowlist.
 */
public final class CloneBlockerEndpoints {
    private static final String[] MANIFEST_URLS = new String[] {
            "https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/blocklist/v3/manifest.json",
            "https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/blocklist/v3/manifest.json",
            "https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/blocklist/v3/manifest.json"
    };

    private static final String[] BLOCKLIST_HOSTS = new String[] {
            "raw.githubusercontent.com",
            "cdn.jsdelivr.net",
            "h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com"
    };

    private static final String[] MANIFEST_PATHS = new String[] {
            "/nsc55/cloneblocker-mirror/published/blocklist/v3/manifest.json",
            "/gh/nsc55/cloneblocker-mirror@published/blocklist/v3/manifest.json",
            "/blocklist/v3/manifest.json"
    };

    private static final String[] OBJECT_BASES = new String[] {
            "https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/blocklist/v3/objects/",
            "https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/blocklist/v3/objects/",
            "https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/blocklist/v3/objects/"
    };

    private static final String[] OBJECT_PREFIXES = new String[] {
            "/nsc55/cloneblocker-mirror/published/blocklist/v3/objects/",
            "/gh/nsc55/cloneblocker-mirror@published/blocklist/v3/objects/",
            "/blocklist/v3/objects/"
    };

    /** Content-addressed object names are exactly 64 lowercase hex digits plus one closed suffix. */
    private static final int OBJECT_HEX_LENGTH = 64;
    private static final String GROUP_SUFFIX = ".json";
    private static final String CHUNK_SUFFIX = ".ndjson.gz";
    private static final String ZERO64 = "0000000000000000000000000000000000000000000000000000000000000000";

    private CloneBlockerEndpoints() {}

    static int blocklistMirrorCount() {
        return MANIFEST_URLS.length;
    }

    static URL manifestUrl(int index) throws Exception {
        requireMirrorIndex(index);
        return exactHttpsUrl(
                MANIFEST_URLS[index],
                BLOCKLIST_HOSTS[index],
                MANIFEST_PATHS[index]);
    }

    static URL objectUrl(int index, String name) throws Exception {
        requireMirrorIndex(index);
        if (!isObjectName(name)) {
            throw new SecurityException("Clone Blocker object name is not allowlisted");
        }
        return exactHttpsUrl(
                OBJECT_BASES[index] + name,
                BLOCKLIST_HOSTS[index],
                OBJECT_PREFIXES[index] + name);
    }

    static void validateConfiguration() throws Exception {
        if (ZERO64.length() != OBJECT_HEX_LENGTH) {
            throw new SecurityException("Clone Blocker object self-test stem is invalid");
        }
        for (int i = 0; i < MANIFEST_URLS.length; i++) {
            manifestUrl(i);
            objectUrl(i, ZERO64 + GROUP_SUFFIX);
            objectUrl(i, ZERO64 + CHUNK_SUFFIX);
            requireRejectedObjectName(i, "ABCD" + ZERO64.substring(4) + GROUP_SUFFIX);
            requireRejectedObjectName(i, ZERO64.substring(1) + GROUP_SUFFIX);
            requireRejectedObjectName(i, ".." + ZERO64.substring(2) + CHUNK_SUFFIX);
            requireRejectedObjectName(i, null);
        }
    }

    private static void requireMirrorIndex(int index) {
        if (index < 0 || index >= MANIFEST_URLS.length) {
            throw new SecurityException("blocklist mirror index is invalid");
        }
    }

    private static boolean isObjectName(String name) {
        if (name == null) {
            return false;
        }
        int length = name.length();
        String suffix;
        if (length == OBJECT_HEX_LENGTH + GROUP_SUFFIX.length()) {
            suffix = GROUP_SUFFIX;
        } else if (length == OBJECT_HEX_LENGTH + CHUNK_SUFFIX.length()) {
            suffix = CHUNK_SUFFIX;
        } else {
            return false;
        }
        for (int i = 0; i < OBJECT_HEX_LENGTH; i++) {
            char c = name.charAt(i);
            boolean digit = c >= '0' && c <= '9';
            boolean lowerHex = c >= 'a' && c <= 'f';
            if (!digit && !lowerHex) {
                return false;
            }
        }
        return name.startsWith(suffix, OBJECT_HEX_LENGTH);
    }

    private static void requireRejectedObjectName(int index, String name) throws Exception {
        boolean rejected = false;
        try {
            objectUrl(index, name);
        } catch (SecurityException expected) {
            rejected = true;
        }
        if (!rejected) {
            throw new SecurityException("Clone Blocker object name allowlist is not fail-closed");
        }
    }

    private static URL exactHttpsUrl(String value, String host, String path)
            throws Exception {
        URL url = new URL(value);
        if (!"https".equalsIgnoreCase(url.getProtocol())
                || !host.equalsIgnoreCase(url.getHost())
                || !path.equals(url.getPath())
                || url.getPort() != -1
                || url.getUserInfo() != null
                || url.getQuery() != null
                || url.getRef() != null
                || !value.equals(url.toExternalForm())) {
            throw new SecurityException("Clone Blocker endpoint is not exactly allowlisted");
        }
        return url;
    }
}
