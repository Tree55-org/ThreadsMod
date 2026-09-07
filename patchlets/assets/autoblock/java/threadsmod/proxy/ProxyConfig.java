package threadsmod.proxy;

import java.net.IDN;
import java.util.Arrays;
import java.util.Locale;

/** Immutable validated SOCKS5 configuration with an explicitly clearable password copy. */
public final class ProxyConfig {
    public static final int DEFAULT_PORT = 1080;
    public static final int MIN_PORT = 1;
    public static final int MAX_PORT = 65535;
    public static final int MAX_HOST_ASCII = 253;
    public static final int MAX_AUTH_BYTES = 255;

    private final boolean enabled;
    private final String host;
    private final int port;
    private final boolean authEnabled;
    private final String username;
    private final char[] password;
    private final ProxyBypassPolicy bypassPolicy;

    private ProxyConfig(
            boolean enabled,
            String host,
            int port,
            boolean authEnabled,
            String username,
            char[] password,
            ProxyBypassPolicy bypassPolicy) {
        this.enabled = enabled;
        this.host = host;
        this.port = port;
        this.authEnabled = authEnabled;
        this.username = username;
        this.password = password == null ? new char[0] : password.clone();
        this.bypassPolicy = bypassPolicy;
    }

    public static ProxyConfig defaults() {
        return new ProxyConfig(
                false, "", DEFAULT_PORT, false, "", new char[0],
                ProxyBypassPolicy.empty());
    }

    /**
     * Validates and canonicalizes one complete configuration.
     *
     * <p>An enabled configuration requires a host. Disabled configuration may retain a valid host
     * for the next connection. Authentication is either completely absent or contains both a
     * printable-ASCII username and password of 1..255 bytes.</p>
     */
    public static ProxyConfig checked(
            boolean enabled,
            String host,
            int port,
            boolean authEnabled,
            String username,
            char[] password,
            String bypassRules) {
        if (port < MIN_PORT || port > MAX_PORT) {
            throw new IllegalArgumentException("SOCKS5 port must be between 1 and 65535.");
        }
        String canonicalHost = canonicalHost(host);
        if (enabled && canonicalHost.length() == 0) {
            throw new IllegalArgumentException("SOCKS5 server is required when proxying is enabled.");
        }
        ProxyBypassPolicy policy = ProxyBypassPolicy.parse(bypassRules);
        if (!authEnabled) {
            return new ProxyConfig(
                    enabled, canonicalHost, port, false, "", new char[0], policy);
        }
        String safeUsername = username == null ? "" : username;
        char[] safePassword = password == null ? new char[0] : password;
        requirePrintableAscii(safeUsername, "SOCKS5 username");
        requirePrintableAscii(safePassword, "SOCKS5 password");
        return new ProxyConfig(
                enabled, canonicalHost, port, true, safeUsername, safePassword, policy);
    }

    public ProxyConfig withEnabled(boolean value) {
        return new ProxyConfig(
                value, host, port, authEnabled, username, password, bypassPolicy);
    }

    public boolean enabled() {
        return enabled;
    }

    public String host() {
        return host;
    }

    public int port() {
        return port;
    }

    public boolean authEnabled() {
        return authEnabled;
    }

    public String username() {
        return username;
    }

    /** Returns a caller-owned copy. The caller must overwrite it after use. */
    public char[] passwordCopy() {
        return password.clone();
    }

    public int passwordLength() {
        return password.length;
    }

    public ProxyBypassPolicy bypassPolicy() {
        return bypassPolicy;
    }

    public String bypassRules() {
        return bypassPolicy.canonicalText();
    }

    /** Best-effort clearing for this in-memory copy; no method renders the password as text. */
    public void clearPassword() {
        Arrays.fill(password, '\0');
    }

    private static String canonicalHost(String value) {
        String input = value == null ? "" : value.trim();
        if (input.length() == 0) {
            return "";
        }
        if (input.startsWith("[") && input.endsWith("]") && input.length() > 2) {
            input = input.substring(1, input.length() - 1);
        } else if (input.indexOf('[') >= 0 || input.indexOf(']') >= 0) {
            throw new IllegalArgumentException("SOCKS5 server address is invalid.");
        }
        if (containsControlOrWhitespace(input) || input.indexOf('/') >= 0
                || input.indexOf('@') >= 0 || input.indexOf('%') >= 0
                || input.indexOf('?') >= 0 || input.indexOf('#') >= 0
                || input.contains("://")) {
            throw new IllegalArgumentException(
                    "SOCKS5 server must be a hostname or numeric IP address, not a URL.");
        }
        if (input.indexOf(':') >= 0) {
            try {
                return ProxyBypassPolicy.canonicalAddress(
                        ProxyBypassPolicy.parseNumericAddress(input));
            } catch (IllegalArgumentException invalid) {
                throw new IllegalArgumentException("SOCKS5 IPv6 server address is invalid.");
            }
        }
        if (looksLikeIpv4(input)) {
            try {
                return ProxyBypassPolicy.canonicalAddress(
                        ProxyBypassPolicy.parseNumericAddress(input));
            } catch (IllegalArgumentException invalid) {
                throw new IllegalArgumentException("SOCKS5 IPv4 server address is invalid.");
            }
        }
        if (input.endsWith(".")) {
            input = input.substring(0, input.length() - 1);
        }
        if (input.length() == 0) {
            throw new IllegalArgumentException("SOCKS5 server hostname is invalid.");
        }
        final String ascii;
        try {
            ascii = IDN.toASCII(input, IDN.USE_STD3_ASCII_RULES)
                    .toLowerCase(Locale.US);
        } catch (IllegalArgumentException invalid) {
            throw new IllegalArgumentException("SOCKS5 server hostname is invalid.");
        }
        if (ascii.length() == 0 || ascii.length() > MAX_HOST_ASCII
                || ascii.startsWith(".") || ascii.endsWith(".")
                || ascii.contains("..")) {
            throw new IllegalArgumentException("SOCKS5 server hostname is invalid.");
        }
        String[] labels = ascii.split("\\.", -1);
        for (String label : labels) {
            if (label.length() == 0 || label.length() > 63) {
                throw new IllegalArgumentException("SOCKS5 server hostname is invalid.");
            }
        }
        return ascii;
    }

    private static boolean looksLikeIpv4(String value) {
        boolean dot = false;
        for (int index = 0; index < value.length(); index++) {
            char next = value.charAt(index);
            if (next == '.') {
                dot = true;
            } else if (next < '0' || next > '9') {
                return false;
            }
        }
        return dot;
    }

    private static boolean containsControlOrWhitespace(String value) {
        for (int index = 0; index < value.length(); index++) {
            char next = value.charAt(index);
            if (Character.isWhitespace(next) || Character.isISOControl(next)) {
                return true;
            }
        }
        return false;
    }

    private static void requirePrintableAscii(String value, String label) {
        if (value.length() < 1 || value.length() > MAX_AUTH_BYTES) {
            throw new IllegalArgumentException(label + " must contain 1 to 255 ASCII bytes.");
        }
        for (int index = 0; index < value.length(); index++) {
            char next = value.charAt(index);
            if (next < 0x20 || next > 0x7e) {
                throw new IllegalArgumentException(label + " must use printable ASCII only.");
            }
        }
    }

    private static void requirePrintableAscii(char[] value, String label) {
        if (value.length < 1 || value.length > MAX_AUTH_BYTES) {
            throw new IllegalArgumentException(label + " must contain 1 to 255 ASCII bytes.");
        }
        for (char next : value) {
            if (next < 0x20 || next > 0x7e) {
                throw new IllegalArgumentException(label + " must use printable ASCII only.");
            }
        }
    }
}
