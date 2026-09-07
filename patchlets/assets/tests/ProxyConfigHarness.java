package threadsmod.proxy;

import java.util.Arrays;

/** Host-JVM checks for the bounded SOCKS5 configuration and numeric bypass grammar. */
public final class ProxyConfigHarness {
    private ProxyConfigHarness() {}

    public static void main(String[] args) {
        verifyPublishedConstantsAndDefaults();
        verifyHostCanonicalizationAndValidation();
        verifyBypassCanonicalizationAndMatching();
        verifyBypassRejectionsAndBounds();
        verifyAuthenticationAndSecretCopies();
        System.out.println(
                "PASS proxy-config defaults=true host=true bypass=true canonical=true "
                + "matching=true rejects=true bounds=64/4096 auth=1-255 failclosed=true");
    }

    private static void verifyPublishedConstantsAndDefaults() {
        require(ProxyConfig.DEFAULT_PORT == 1080, "default port constant");
        require(ProxyConfig.MIN_PORT == 1, "minimum port constant");
        require(ProxyConfig.MAX_PORT == 65535, "maximum port constant");
        require(ProxyConfig.MAX_HOST_ASCII == 253, "hostname bound constant");
        require(ProxyConfig.MAX_AUTH_BYTES == 255, "authentication bound constant");
        require(ProxyBypassPolicy.MAX_RULES == 64, "bypass rule bound constant");
        require(ProxyBypassPolicy.MAX_TEXT_UTF16 == 4096, "bypass text bound constant");

        ProxyConfig defaults = ProxyConfig.defaults();
        require(!defaults.enabled(), "default disabled");
        require(defaults.host().length() == 0, "default host empty");
        require(defaults.port() == 1080, "default port");
        require(!defaults.authEnabled(), "default authentication disabled");
        require(defaults.username().length() == 0, "default username empty");
        require(defaults.passwordLength() == 0, "default password empty");
        require(defaults.bypassPolicy().isEmpty(), "default bypass empty");

        ProxyConfig disabled = ProxyConfig.checked(
                false, null, 1, false, "discarded", new char[] {'d'}, null);
        require(!disabled.enabled(), "explicit disabled state");
        require(disabled.host().length() == 0, "disabled blank host accepted");
        require(disabled.port() == 1, "minimum port accepted");
        require(!disabled.authEnabled(), "disabled auth remains off");
        require(disabled.username().length() == 0, "auth-off username discarded");
        require(disabled.passwordLength() == 0, "auth-off password discarded");

        ProxyConfig maximumPort = ProxyConfig.checked(
                true, "127.0.0.1", 65535, false, null, null, "");
        require(maximumPort.port() == 65535, "maximum port accepted");
        expectConfigInvalid(true, "127.0.0.1", 0, false, "", new char[0], "",
                "port below minimum");
        expectConfigInvalid(true, "127.0.0.1", 65536, false, "", new char[0], "",
                "port above maximum");
        expectConfigInvalid(true, "", 1080, false, "", new char[0], "",
                "enabled blank host");
        expectConfigInvalid(true, null, 1080, false, "", new char[0], "",
                "enabled missing host");
    }

    private static void verifyHostCanonicalizationAndValidation() {
        require(configHost(" 192.168.001.001 ").equals("192.168.1.1"),
                "IPv4 canonicalization");
        require(configHost("[2001:0DB8:0:0:0:0:0:1]").equals("2001:db8::1"),
                "bracketed IPv6 canonicalization");
        require(configHost("EXAMPLE.COM.").equals("example.com"),
                "hostname case and terminal dot canonicalization");
        require(configHost("b\u00fccher.example").equals("xn--bcher-kva.example"),
                "IDNA hostname canonicalization");

        String[] invalidHosts = new String[] {
            "https://proxy.example", "proxy.example/path", "user@proxy.example",
            "proxy.example?x=1", "proxy.example#fragment", "proxy.example%zone",
            "*.proxy.example", "proxy.example:1080", "[2001:db8::1",
            "2001:db8::1]", "256.1.1.1", "1.2.3", "1.2.3.4.5",
            "proxy example", ".proxy.example", "proxy..example", "-bad.example"
        };
        for (String invalid : invalidHosts) {
            expectConfigInvalid(true, invalid, 1080, false, "", new char[0], "",
                    "invalid host " + invalid);
        }
        String tooLong = repeat('a', 63) + "." + repeat('b', 63) + "."
                + repeat('c', 63) + "." + repeat('d', 63);
        expectConfigInvalid(true, tooLong, 1080, false, "", new char[0], "",
                "hostname over 253 ASCII characters");
    }

    private static void verifyBypassCanonicalizationAndMatching() {
        String raw = " 192.168.001.001 \r\n\r\n"
                + "10.2.3.4/8\n"
                + "2001:0DB8:0:0:0:0:0:1\r"
                + "2001:db9:abcd::1/32";
        ProxyBypassPolicy policy = ProxyBypassPolicy.parse(raw);
        require(policy.size() == 4, "four canonical bypass entries");
        require(policy.canonicalText().equals(
                "192.168.1.1\n10.0.0.0/8\n2001:db8::1\n2001:db9::/32"),
                "ordered canonical bypass text");

        require(policy.shouldBypass("192.168.1.1"), "exact IPv4 match");
        require(!policy.shouldBypass("192.168.1.2"), "exact IPv4 mismatch");
        require(policy.shouldBypass("10.255.254.253"), "IPv4 CIDR match");
        require(!policy.shouldBypass("11.0.0.1"), "IPv4 CIDR mismatch");
        require(policy.shouldBypass("2001:db8::1"), "exact IPv6 match");
        require(!policy.shouldBypass("2001:db8::2"), "exact IPv6 mismatch");
        require(policy.shouldBypass("2001:db9:ffff::1234"), "IPv6 CIDR match");
        require(!policy.shouldBypass("2001:dba::1"), "IPv6 CIDR mismatch");
        require(!policy.shouldBypass("proxy.example"), "hostname never bypasses");
        require(!policy.shouldBypass("https://10.0.0.1"), "URL never bypasses");
        require(!policy.shouldBypass("[2001:db8::1]"), "bracketed destination rejected");

        ProxyBypassPolicy edgePrefixes = ProxyBypassPolicy.parse(
                "203.0.113.77/0\n2001:db8::1/0");
        require(edgePrefixes.canonicalText().equals("0.0.0.0/0\n::/0"),
                "zero prefixes canonicalized to each family root");
        require(edgePrefixes.shouldBypass("8.8.8.8"), "IPv4 zero prefix match");
        require(edgePrefixes.shouldBypass("2001:4860:4860::8888"),
                "IPv6 zero prefix match");
    }

    private static void verifyBypassRejectionsAndBounds() {
        String[] invalidRules = new String[] {
            "proxy.example", "https://10.0.0.1", "*.example", "10.*",
            "[2001:db8::1]", "fe80::1%wlan0", "1.2.3", "1.2.3.4.5",
            "256.0.0.1", "1..2.3", "1.2.3.-1", "1.2.3.4:80",
            "10.0.0.1/", "/24", "10.0.0.1/33", "2001:db8::1/129",
            "10.0.0.1/-1", "10.0.0.1/+8", "10.0.0.1/ 8",
            "10.0.0.1/8/9", "::ffff:192.0.2.1"
        };
        for (String invalid : invalidRules) {
            expectPolicyInvalid(invalid, "invalid bypass rule " + invalid);
        }
        expectPolicyInvalid("010.000.000.001\n10.0.0.1",
                "duplicate after IPv4 canonicalization");
        expectPolicyInvalid("10.1.1.1/8\n10.2.2.2/08",
                "duplicate after CIDR canonicalization");

        StringBuilder sixtyFour = new StringBuilder();
        for (int index = 0; index < 64; index++) {
            if (index > 0) {
                sixtyFour.append('\n');
            }
            sixtyFour.append("192.0.2.").append(index);
        }
        ProxyBypassPolicy maximum = ProxyBypassPolicy.parse(sixtyFour.toString());
        require(maximum.size() == 64, "exact 64-rule bound accepted");
        expectPolicyInvalid(sixtyFour.toString() + "\n192.0.2.64",
                "65th rule rejected");

        String exactTextBound = repeat(' ', 4096);
        require(ProxyBypassPolicy.parse(exactTextBound).isEmpty(),
                "exact 4096 UTF-16 bound accepted");
        expectPolicyInvalid(exactTextBound + " ", "4097th UTF-16 unit rejected");
    }

    private static void verifyAuthenticationAndSecretCopies() {
        ProxyConfig minimum = ProxyConfig.checked(
                true, "127.0.0.1", 1080, true, "u", new char[] {'p'}, "");
        require(minimum.authEnabled(), "minimum authentication accepted");
        require(minimum.username().equals("u"), "minimum username preserved");
        require(minimum.passwordLength() == 1, "minimum password preserved");

        String maximumUsername = repeat('u', 255);
        char[] maximumPassword = repeat('p', 255).toCharArray();
        ProxyConfig maximum = ProxyConfig.checked(
                true, "127.0.0.1", 1080, true,
                maximumUsername, maximumPassword, "");
        require(maximum.username().length() == 255, "255-byte username accepted");
        require(maximum.passwordLength() == 255, "255-byte password accepted");

        expectConfigInvalid(true, "127.0.0.1", 1080, true, "", new char[] {'p'}, "",
                "empty username");
        expectConfigInvalid(true, "127.0.0.1", 1080, true, "u", new char[0], "",
                "empty password");
        expectConfigInvalid(true, "127.0.0.1", 1080, true,
                repeat('u', 256), new char[] {'p'}, "", "256-byte username");
        expectConfigInvalid(true, "127.0.0.1", 1080, true,
                "u", repeat('p', 256).toCharArray(), "", "256-byte password");
        expectConfigInvalid(true, "127.0.0.1", 1080, true,
                "us\u00e9r", new char[] {'p'}, "", "non-ASCII username");
        expectConfigInvalid(true, "127.0.0.1", 1080, true,
                "u", new char[] {'p', '\n'}, "", "control password");
        expectConfigInvalid(true, "127.0.0.1", 1080, true,
                "u\u007f", new char[] {'p'}, "", "DEL username");

        char[] source = new char[] {'s', 'e', 'c', 'r', 'e', 't'};
        ProxyConfig copied = ProxyConfig.checked(
                true, "127.0.0.1", 1080, true, "user", source, "");
        source[0] = 'X';
        char[] firstCopy = copied.passwordCopy();
        require(firstCopy[0] == 's', "constructor password copy");
        firstCopy[0] = 'Y';
        char[] secondCopy = copied.passwordCopy();
        require(secondCopy[0] == 's', "getter password copy");
        Arrays.fill(firstCopy, '\0');
        Arrays.fill(secondCopy, '\0');
        copied.clearPassword();
        char[] cleared = copied.passwordCopy();
        for (char next : cleared) {
            require(next == '\0', "in-memory password clear");
        }
        Arrays.fill(cleared, '\0');
        maximum.clearPassword();
        minimum.clearPassword();
    }

    private static String configHost(String host) {
        ProxyConfig config = ProxyConfig.checked(
                true, host, 1080, false, null, null, "");
        return config.host();
    }

    private static void expectPolicyInvalid(String value, String label) {
        try {
            ProxyBypassPolicy.parse(value);
            throw new AssertionError("invalid bypass policy was accepted: " + label);
        } catch (IllegalArgumentException expected) {
            // Expected fail-closed validation.
        }
    }

    private static void expectConfigInvalid(
            boolean enabled,
            String host,
            int port,
            boolean authEnabled,
            String username,
            char[] password,
            String bypass,
            String label) {
        try {
            ProxyConfig.checked(
                    enabled, host, port, authEnabled, username, password, bypass);
            throw new AssertionError("invalid proxy configuration was accepted: " + label);
        } catch (IllegalArgumentException expected) {
            // Expected fail-closed validation.
        }
    }

    private static String repeat(char value, int count) {
        char[] result = new char[count];
        Arrays.fill(result, value);
        return new String(result);
    }

    private static void require(boolean value, String label) {
        if (!value) {
            throw new AssertionError(label);
        }
    }
}
