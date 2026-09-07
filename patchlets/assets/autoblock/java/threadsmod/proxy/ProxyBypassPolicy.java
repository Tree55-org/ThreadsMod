package threadsmod.proxy;

import java.net.Inet6Address;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Immutable, ordered DIRECT exceptions for the app-wide proxy.
 *
 * <p>The grammar deliberately accepts numeric addresses only. Each non-empty line is either an
 * IPv4/IPv6 address or a CIDR. Hostname bypass needs DNS-to-flow binding and is therefore not
 * accepted by this version.</p>
 */
public final class ProxyBypassPolicy {
    public static final int MAX_RULES = 64;
    public static final int MAX_TEXT_UTF16 = 4096;

    private final List<Rule> rules;
    private final String canonicalText;

    private ProxyBypassPolicy(List<Rule> rules, String canonicalText) {
        this.rules = Collections.unmodifiableList(new ArrayList<Rule>(rules));
        this.canonicalText = canonicalText;
    }

    public static ProxyBypassPolicy empty() {
        return new ProxyBypassPolicy(Collections.<Rule>emptyList(), "");
    }

    /** Parses, canonicalizes, and bounds one numeric address or CIDR per non-empty line. */
    public static ProxyBypassPolicy parse(String value) {
        String raw = value == null ? "" : value;
        if (raw.length() > MAX_TEXT_UTF16) {
            throw new IllegalArgumentException(
                    "Bypass rules must be at most " + MAX_TEXT_UTF16 + " characters.");
        }
        String[] lines = raw.split("\\r\\n|\\n|\\r", -1);
        ArrayList<Rule> parsed = new ArrayList<Rule>();
        Set<String> seen = new LinkedHashSet<String>();
        StringBuilder canonical = new StringBuilder();
        for (int index = 0; index < lines.length; index++) {
            String line = lines[index].trim();
            if (line.length() == 0) {
                continue;
            }
            if (parsed.size() >= MAX_RULES) {
                throw new IllegalArgumentException(
                        "Bypass rules may contain at most " + MAX_RULES + " entries.");
            }
            Rule rule = parseRule(line, index + 1);
            if (!seen.add(rule.canonical)) {
                throw new IllegalArgumentException(
                        "Bypass rule " + (index + 1) + " duplicates an earlier rule.");
            }
            parsed.add(rule);
            if (canonical.length() > 0) {
                canonical.append('\n');
            }
            canonical.append(rule.canonical);
        }
        if (canonical.length() > MAX_TEXT_UTF16) {
            throw new IllegalArgumentException(
                    "Canonical bypass rules exceed the storage limit.");
        }
        return new ProxyBypassPolicy(parsed, canonical.toString());
    }

    /** Returns DIRECT only for a valid numeric destination matched by the first ordered rule. */
    public boolean shouldBypass(String numericDestination) {
        final AddressValue destination;
        try {
            destination = parseNumericAddress(numericDestination);
        } catch (IllegalArgumentException invalid) {
            return false;
        }
        for (Rule rule : rules) {
            if (rule.matches(destination)) {
                return true;
            }
        }
        return false;
    }

    public int size() {
        return rules.size();
    }

    public boolean isEmpty() {
        return rules.isEmpty();
    }

    public String canonicalText() {
        return canonicalText;
    }

    private static Rule parseRule(String value, int lineNumber) {
        int slash = value.indexOf('/');
        if (slash != value.lastIndexOf('/')) {
            throw invalidRule(lineNumber);
        }
        if (slash < 0) {
            AddressValue address = parseRuleAddress(value, lineNumber);
            return new Rule(address.bytes, address.bitCount, false,
                    canonicalAddress(address.bytes));
        }
        if (slash == 0 || slash == value.length() - 1) {
            throw invalidRule(lineNumber);
        }
        AddressValue address = parseRuleAddress(value.substring(0, slash), lineNumber);
        String prefixText = value.substring(slash + 1);
        if (!isAsciiDigits(prefixText)) {
            throw invalidRule(lineNumber);
        }
        final int prefix;
        try {
            prefix = Integer.parseInt(prefixText);
        } catch (NumberFormatException invalid) {
            throw invalidRule(lineNumber);
        }
        if (prefix < 0 || prefix > address.bitCount) {
            throw invalidRule(lineNumber);
        }
        byte[] network = masked(address.bytes, prefix);
        return new Rule(network, prefix, true,
                canonicalAddress(network) + "/" + prefix);
    }

    private static AddressValue parseRuleAddress(String value, int lineNumber) {
        try {
            return parseNumericAddress(value);
        } catch (IllegalArgumentException invalid) {
            throw invalidRule(lineNumber);
        }
    }

    private static IllegalArgumentException invalidRule(int lineNumber) {
        return new IllegalArgumentException(
                "Bypass rule " + lineNumber + " must be a numeric IPv4/IPv6 address or CIDR.");
    }

    static AddressValue parseNumericAddress(String value) {
        if (value == null) {
            throw new IllegalArgumentException("Numeric address is missing.");
        }
        String input = value.trim();
        if (input.length() == 0 || input.indexOf('%') >= 0
                || input.indexOf('[') >= 0 || input.indexOf(']') >= 0
                || containsControlOrWhitespace(input)) {
            throw new IllegalArgumentException("Numeric address is invalid.");
        }
        if (input.indexOf(':') >= 0) {
            try {
                InetAddress parsed = InetAddress.getByName(input);
                if (!(parsed instanceof Inet6Address)) {
                    throw new IllegalArgumentException("IPv6 address is invalid.");
                }
                byte[] bytes = parsed.getAddress();
                if (bytes == null || bytes.length != 16) {
                    throw new IllegalArgumentException("IPv6 address is invalid.");
                }
                return new AddressValue(bytes, 128);
            } catch (Exception invalid) {
                throw new IllegalArgumentException("IPv6 address is invalid.");
            }
        }
        return parseIpv4(input);
    }

    static String canonicalAddress(AddressValue address) {
        return canonicalAddress(address.bytes);
    }

    private static AddressValue parseIpv4(String value) {
        String[] parts = value.split("\\.", -1);
        if (parts.length != 4) {
            throw new IllegalArgumentException("IPv4 address is invalid.");
        }
        byte[] bytes = new byte[4];
        for (int index = 0; index < parts.length; index++) {
            String part = parts[index];
            if (part.length() == 0 || part.length() > 3 || !isAsciiDigits(part)) {
                throw new IllegalArgumentException("IPv4 address is invalid.");
            }
            int number;
            try {
                number = Integer.parseInt(part);
            } catch (NumberFormatException invalid) {
                throw new IllegalArgumentException("IPv4 address is invalid.");
            }
            if (number < 0 || number > 255) {
                throw new IllegalArgumentException("IPv4 address is invalid.");
            }
            bytes[index] = (byte) number;
        }
        return new AddressValue(bytes, 32);
    }

    private static boolean isAsciiDigits(String value) {
        if (value == null || value.length() == 0) {
            return false;
        }
        for (int index = 0; index < value.length(); index++) {
            char next = value.charAt(index);
            if (next < '0' || next > '9') {
                return false;
            }
        }
        return true;
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

    private static byte[] masked(byte[] source, int prefix) {
        byte[] result = source.clone();
        int remaining = prefix;
        for (int index = 0; index < result.length; index++) {
            if (remaining >= 8) {
                remaining -= 8;
            } else if (remaining <= 0) {
                result[index] = 0;
            } else {
                int mask = 0xff << (8 - remaining);
                result[index] = (byte) ((result[index] & 0xff) & mask);
                remaining = 0;
            }
        }
        return result;
    }

    private static String canonicalAddress(byte[] bytes) {
        if (bytes.length == 4) {
            return (bytes[0] & 0xff) + "." + (bytes[1] & 0xff) + "."
                    + (bytes[2] & 0xff) + "." + (bytes[3] & 0xff);
        }
        if (bytes.length != 16) {
            throw new IllegalArgumentException("Address family is invalid.");
        }
        int[] words = new int[8];
        for (int index = 0; index < words.length; index++) {
            words[index] = ((bytes[index * 2] & 0xff) << 8)
                    | (bytes[index * 2 + 1] & 0xff);
        }
        int bestStart = -1;
        int bestLength = 0;
        for (int index = 0; index < words.length;) {
            if (words[index] != 0) {
                index++;
                continue;
            }
            int end = index;
            while (end < words.length && words[end] == 0) {
                end++;
            }
            int length = end - index;
            if (length >= 2 && length > bestLength) {
                bestStart = index;
                bestLength = length;
            }
            index = end;
        }
        StringBuilder output = new StringBuilder(39);
        for (int index = 0; index < words.length;) {
            if (index == bestStart) {
                output.append("::");
                index += bestLength;
                continue;
            }
            if (output.length() > 0 && output.charAt(output.length() - 1) != ':') {
                output.append(':');
            }
            output.append(Integer.toHexString(words[index]).toLowerCase(Locale.US));
            index++;
        }
        return output.length() == 0 ? "::" : output.toString();
    }

    static final class AddressValue {
        final byte[] bytes;
        final int bitCount;

        AddressValue(byte[] bytes, int bitCount) {
            this.bytes = bytes.clone();
            this.bitCount = bitCount;
        }
    }

    private static final class Rule {
        final byte[] network;
        final int prefix;
        final boolean cidr;
        final String canonical;

        Rule(byte[] network, int prefix, boolean cidr, String canonical) {
            this.network = network.clone();
            this.prefix = prefix;
            this.cidr = cidr;
            this.canonical = canonical;
        }

        boolean matches(AddressValue address) {
            if (address.bytes.length != network.length) {
                return false;
            }
            int fullBytes = prefix / 8;
            int remaining = prefix % 8;
            for (int index = 0; index < fullBytes; index++) {
                if (address.bytes[index] != network[index]) {
                    return false;
                }
            }
            if (remaining == 0) {
                return true;
            }
            int mask = 0xff << (8 - remaining);
            return ((address.bytes[fullBytes] & 0xff) & mask)
                    == ((network[fullBytes] & 0xff) & mask);
        }
    }
}
