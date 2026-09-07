package threadsmod.update;

import java.net.URL;
import java.util.Locale;

/** Exact, ISP-resilient update metadata and artifact transport policy. */
public final class UpdateEndpoints {
    private static final int MAX_INITIAL_URL_CHARS = 1024;
    private static final int MAX_REDIRECT_LOCATION_CHARS = 4096;
    private static final int MAX_REDIRECT_URL_CHARS = 4096;
    private static final int MAX_REDIRECT_PATH_CHARS = 2048;
    private static final int MAX_REDIRECT_QUERY_CHARS = 2048;
    private static final String[] METADATA_URLS = new String[] {
            "https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/threadsmod-update.json",
            "https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/threadsmod-update.json",
            "https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/threadsmod-update.json"
    };

    private static final String[] METADATA_HOSTS = new String[] {
            "raw.githubusercontent.com",
            "cdn.jsdelivr.net",
            "h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com"
    };

    private static final String[] METADATA_PATHS = new String[] {
            "/nsc55/cloneblocker-mirror/published/threadsmod-update.json",
            "/gh/nsc55/cloneblocker-mirror@published/threadsmod-update.json",
            "/threadsmod-update.json"
    };

    static final int PROVIDER_GITHUB = 1;
    static final int PROVIDER_AWS = 2;

    private UpdateEndpoints() {}

    static int metadataMirrorCount() {
        return METADATA_URLS.length;
    }

    static URL metadataMirror(int index) throws Exception {
        if (index < 0 || index >= METADATA_URLS.length) {
            throw new SecurityException("update metadata mirror index is invalid");
        }
        return exactHttpsUrl(
                METADATA_URLS[index], METADATA_HOSTS[index], METADATA_PATHS[index]);
    }

    static URL validateArtifactUrl(String value, String artifactName)
            throws Exception {
        if (value == null || artifactName == null) {
            throw new SecurityException("update artifact URL input is invalid");
        }
        if (value.length() > MAX_INITIAL_URL_CHARS) {
            throw new SecurityException("update artifact URL exceeds its bound");
        }
        URL url = new URL(value);
        if (!"https".equalsIgnoreCase(url.getProtocol())
                || (url.getPort() != -1 && url.getPort() != 443)
                || url.getUserInfo() != null
                || url.getQuery() != null
                || url.getRef() != null
                || !value.equals(url.toExternalForm())) {
            throw new SecurityException("update artifact URL is not exact HTTPS");
        }
        int provider = artifactProvider(url);
        if (provider == 0 || !url.getPath().endsWith("/" + artifactName)) {
            throw new SecurityException("update artifact mirror is outside the allowlist");
        }
        if (provider == PROVIDER_GITHUB
                && !("github.com".equals(url.getHost().toLowerCase(Locale.US))
                && url.getPath().matches(
                "^/nsc55/cloneblocker-mirror/releases/download/[^/]+/[^/]+\\.apk$"))) {
            throw new SecurityException("initial GitHub artifact URL is not a release URL");
        }
        return url;
    }

    static URL validateRedirect(URL previous, String location, String artifactName, int hop)
            throws Exception {
        if (previous == null || location == null || location.length() == 0
                || location.length() > MAX_REDIRECT_LOCATION_CHARS
                || hop < 1 || hop > 3) {
            throw new SecurityException("update redirect is invalid");
        }
        URL next = new URL(previous, location);
        if (!"https".equalsIgnoreCase(next.getProtocol())
                || (next.getPort() != -1 && next.getPort() != 443)
                || next.getUserInfo() != null
                || next.getRef() != null
                || next.toExternalForm().length() > MAX_REDIRECT_URL_CHARS
                || next.getQuery() != null
                && next.getQuery().length() > MAX_REDIRECT_QUERY_CHARS
                || next.getPath() == null || next.getPath().length() == 0
                || next.getPath().length() > MAX_REDIRECT_PATH_CHARS) {
            throw new SecurityException("update redirect is outside the transport policy");
        }
        int previousProvider = artifactProvider(previous);
        int nextProvider = artifactProvider(next);
        if (previousProvider == 0 || previousProvider != nextProvider) {
            throw new SecurityException("update redirect crosses provider classes");
        }
        if (nextProvider == PROVIDER_GITHUB) {
            String host = next.getHost().toLowerCase(Locale.US);
            if (!("github.com".equals(host)
                    || "release-assets.githubusercontent.com".equals(host)
                    || "objects.githubusercontent.com".equals(host))) {
                throw new SecurityException("update GitHub redirect host is invalid");
            }
            if ("github.com".equals(host)
                    && !next.getPath().endsWith("/" + artifactName)) {
                throw new SecurityException("update GitHub release redirect is invalid");
            }
        } else if (!next.getPath().endsWith("/" + artifactName)) {
            throw new SecurityException("update AWS redirect artifact is invalid");
        }
        return next;
    }

    static int artifactProvider(URL url) {
        if (url == null || url.getHost() == null) return 0;
        String host = url.getHost().toLowerCase(Locale.US);
        if ("github.com".equals(host)
                || "release-assets.githubusercontent.com".equals(host)
                || "objects.githubusercontent.com".equals(host)) {
            return PROVIDER_GITHUB;
        }
        if (isPublicAwsObjectHost(host)) return PROVIDER_AWS;
        return 0;
    }

    private static boolean isPublicAwsObjectHost(String host) {
        if (host == null || host.length() > 253 || isIpLiteral(host)
                || host.equals("localhost") || host.endsWith(".localhost")
                || host.endsWith(".local")) return false;
        if (host.matches("^[a-z0-9]{1,63}\\.cloudfront\\.net$")) {
            return true;
        }
        if (!host.matches(
                "^.+\\.s3\\.[a-z]{2}(?:-gov)?-[a-z0-9-]+-[0-9]\\.amazonaws\\.com$")) {
            return false;
        }
        String bucket = host.substring(0, host.lastIndexOf(".s3."));
        if (bucket.length() < 3 || bucket.length() > 63
                || bucket.indexOf('.') >= 0 || isIpLiteral(bucket)) return false;
        return bucket.matches("^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$");
    }

    private static boolean isIpLiteral(String host) {
        if (host.indexOf(':') >= 0) return true;
        return host.matches("^[0-9.]+$");
    }

    static void validateConfiguration() throws Exception {
        for (int i = 0; i < METADATA_URLS.length; i++) {
            metadataMirror(i);
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
            throw new SecurityException("update endpoint is not exactly allowlisted");
        }
        return url;
    }
}
