package threadsmod.video;

import java.net.URI;
import java.net.URL;
import java.util.Locale;

/** Immutable public-media input; no account state or host objects cross this boundary. */
public final class VideoSaveRequest {
    public static final int MAX_URL_LENGTH = 8192;
    public final String url;
    public final String suggestedFilename;

    public VideoSaveRequest(String url, String suggestedFilename) {
        validateUrl(url);
        if (suggestedFilename == null || suggestedFilename.length() > 96
                || !suggestedFilename.matches("[A-Za-z0-9][A-Za-z0-9 _.-]*\\.mp4")
                || suggestedFilename.contains("..")) {
            throw new IllegalArgumentException("video filename invalid");
        }
        this.url = url;
        this.suggestedFilename = suggestedFilename;
    }

    public static URL validateUrl(String value) {
        if (value == null || value.length() == 0 || value.length() > MAX_URL_LENGTH) {
            throw new IllegalArgumentException("video URL invalid");
        }
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c <= 32 || c >= 127 || c == '\\') {
                throw new IllegalArgumentException("video URL invalid");
            }
        }
        try {
            URI uri = new URI(value);
            String host = uri.getHost();
            if (!"https".equals(uri.getScheme()) || uri.getRawUserInfo() != null
                    || uri.getRawFragment() != null || uri.getPort() != -1
                    || host == null || uri.getRawPath() == null
                    || !uri.getRawPath().startsWith("/") || uri.getRawPath().length() < 2
                    || !allowedHost(host.toLowerCase(Locale.US))) {
                throw new IllegalArgumentException("video URL invalid");
            }
            return uri.toURL();
        } catch (Exception invalid) {
            throw new IllegalArgumentException("video URL invalid");
        }
    }

    public static boolean isAllowed(String value) {
        try {
            validateUrl(value);
            return true;
        } catch (IllegalArgumentException invalid) {
            return false;
        }
    }

    private static boolean allowedHost(String host) {
        return host.equals("cdninstagram.com") || host.endsWith(".cdninstagram.com")
                || host.equals("fbcdn.net") || host.endsWith(".fbcdn.net");
    }

    static URL redirect(URL source, String location, int hops) {
        if (hops < 1 || hops > 3 || location == null
                || location.length() == 0 || location.length() > MAX_URL_LENGTH) {
            throw new IllegalArgumentException("video redirect invalid");
        }
        try {
            // URI resolution preserves strict user-info, port, fragment and host validation.
            return validateUrl(source.toURI().resolve(new URI(location)).toASCIIString());
        } catch (Exception invalid) {
            throw new IllegalArgumentException("video redirect invalid");
        }
    }
}
