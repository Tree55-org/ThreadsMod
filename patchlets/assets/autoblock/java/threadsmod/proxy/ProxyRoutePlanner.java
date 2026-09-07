package threadsmod.proxy;

import android.net.IpPrefix;
import android.net.VpnService;
import android.os.Build;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * Produces an exact, bounded VPN route plan for numeric DIRECT exceptions.
 *
 * <p>Android 13 and newer express the policy as two default routes plus excluded prefixes. Older
 * Android releases have no exclusion API, so this class emits the exact CIDR complement instead.
 * A plan that cannot fit inside the fixed route bound is rejected; callers must then retain a
 * full-route blackhole rather than silently allowing direct traffic.</p>
 */
public final class ProxyRoutePlanner {
    /** Includes the user policy and a bounded set of pre-resolved SOCKS infrastructure addresses. */
    public static final int MAX_EXCLUDED_PREFIXES = ProxyBypassPolicy.MAX_RULES + 16;

    /** Prevents a pathological old-Android complement from creating an unbounded Builder. */
    public static final int MAX_COMPLEMENT_ROUTES = 4096;

    private ProxyRoutePlanner() {}

    public static Plan create(
            ProxyBypassPolicy bypassPolicy, InetAddress[] socksEndpointAddresses) {
        if (bypassPolicy == null || socksEndpointAddresses == null
                || socksEndpointAddresses.length == 0
                || socksEndpointAddresses.length > 16) {
            throw new IllegalArgumentException("Proxy route inputs are invalid.");
        }

        ArrayList<Prefix> exclusions = new ArrayList<Prefix>();
        String canonical = bypassPolicy.canonicalText();
        if (canonical.length() > 0) {
            String[] lines = canonical.split("\\n", -1);
            for (String line : lines) {
                if (line.length() == 0) {
                    throw new IllegalArgumentException("Canonical bypass policy is invalid.");
                }
                exclusions.add(parseCanonicalPrefix(line));
            }
        }
        for (InetAddress address : socksEndpointAddresses) {
            if (address == null) {
                throw new IllegalArgumentException("SOCKS5 infrastructure address is invalid.");
            }
            byte[] bytes = address.getAddress();
            if (bytes == null || (bytes.length != 4 && bytes.length != 16)) {
                throw new IllegalArgumentException("SOCKS5 infrastructure address is invalid.");
            }
            exclusions.add(new Prefix(bytes, bytes.length * 8));
        }
        if (exclusions.size() > MAX_EXCLUDED_PREFIXES) {
            throw new IllegalArgumentException("Proxy exclusion count exceeds the safe bound.");
        }

        List<Prefix> normalized = normalize(exclusions);
        ArrayList<Prefix> ipv4Routes = new ArrayList<Prefix>();
        ArrayList<Prefix> ipv6Routes = new ArrayList<Prefix>();
        if (Build.VERSION.SDK_INT < 33) {
            ipv4Routes = complement(normalized, 32);
            ipv6Routes = complement(normalized, 128);
            if (ipv4Routes.size() + ipv6Routes.size() > MAX_COMPLEMENT_ROUTES) {
                throw new IllegalArgumentException(
                        "Proxy route complement exceeds the safe bound.");
            }
        }
        return new Plan(normalized, ipv4Routes, ipv6Routes);
    }

    /** Immutable result that can be applied only to the Builder owned by the VPN service. */
    public static final class Plan {
        private final List<Prefix> exclusions;
        private final List<Prefix> ipv4Routes;
        private final List<Prefix> ipv6Routes;

        private Plan(
                List<Prefix> exclusions,
                List<Prefix> ipv4Routes,
                List<Prefix> ipv6Routes) {
            this.exclusions = immutableCopy(exclusions);
            this.ipv4Routes = immutableCopy(ipv4Routes);
            this.ipv6Routes = immutableCopy(ipv6Routes);
        }

        /** Applies either native exclusions or the precomputed exact complement. */
        public void apply(VpnService.Builder builder) {
            if (builder == null) {
                throw new IllegalArgumentException("VPN builder is missing.");
            }
            if (Build.VERSION.SDK_INT >= 33) {
                addRoute(builder, new byte[4], 0);
                addRoute(builder, new byte[16], 0);
                for (Prefix prefix : exclusions) {
                    builder.excludeRoute(new IpPrefix(toInetAddress(prefix.network), prefix.length));
                }
                return;
            }
            for (Prefix prefix : ipv4Routes) {
                addRoute(builder, prefix.network, prefix.length);
            }
            for (Prefix prefix : ipv6Routes) {
                addRoute(builder, prefix.network, prefix.length);
            }
        }

        public int exclusionCount() {
            return exclusions.size();
        }

        public int legacyRouteCount() {
            return ipv4Routes.size() + ipv6Routes.size();
        }
    }

    private static Prefix parseCanonicalPrefix(String value) {
        int slash = value.indexOf('/');
        String addressText = slash < 0 ? value : value.substring(0, slash);
        ProxyBypassPolicy.AddressValue address =
                ProxyBypassPolicy.parseNumericAddress(addressText);
        int prefix = address.bitCount;
        if (slash >= 0) {
            if (slash == 0 || slash == value.length() - 1
                    || slash != value.lastIndexOf('/')) {
                throw new IllegalArgumentException("Canonical bypass prefix is invalid.");
            }
            try {
                prefix = Integer.parseInt(value.substring(slash + 1));
            } catch (NumberFormatException invalid) {
                throw new IllegalArgumentException("Canonical bypass prefix is invalid.");
            }
        }
        if (prefix < 0 || prefix > address.bitCount) {
            throw new IllegalArgumentException("Canonical bypass prefix is invalid.");
        }
        return new Prefix(masked(address.bytes, prefix), prefix);
    }

    private static List<Prefix> normalize(List<Prefix> input) {
        ArrayList<Prefix> ordered = new ArrayList<Prefix>(input);
        Collections.sort(ordered, new Comparator<Prefix>() {
            @Override
            public int compare(Prefix left, Prefix right) {
                if (left.network.length != right.network.length) {
                    return left.network.length - right.network.length;
                }
                if (left.length != right.length) {
                    return left.length - right.length;
                }
                for (int index = 0; index < left.network.length; index++) {
                    int difference = (left.network[index] & 0xff)
                            - (right.network[index] & 0xff);
                    if (difference != 0) {
                        return difference;
                    }
                }
                return 0;
            }
        });

        ArrayList<Prefix> result = new ArrayList<Prefix>();
        for (Prefix candidate : ordered) {
            boolean covered = false;
            for (Prefix accepted : result) {
                if (contains(accepted, candidate)) {
                    covered = true;
                    break;
                }
            }
            if (!covered) {
                result.add(candidate);
            }
        }
        return result;
    }

    private static ArrayList<Prefix> complement(List<Prefix> exclusions, int bitCount) {
        TrieNode root = new TrieNode();
        boolean hasExclusion = false;
        for (Prefix exclusion : exclusions) {
            if (exclusion.network.length * 8 != bitCount) {
                continue;
            }
            insert(root, exclusion, 0);
            hasExclusion = true;
        }
        ArrayList<Prefix> result = new ArrayList<Prefix>();
        if (!hasExclusion) {
            result.add(new Prefix(new byte[bitCount / 8], 0));
            return result;
        }
        collectComplement(root, new byte[bitCount / 8], 0, bitCount, result);
        return result;
    }

    private static void insert(TrieNode node, Prefix prefix, int depth) {
        if (node.excluded) {
            return;
        }
        if (depth == prefix.length) {
            node.excluded = true;
            node.zero = null;
            node.one = null;
            return;
        }
        if (bit(prefix.network, depth) == 0) {
            if (node.zero == null) {
                node.zero = new TrieNode();
            }
            insert(node.zero, prefix, depth + 1);
        } else {
            if (node.one == null) {
                node.one = new TrieNode();
            }
            insert(node.one, prefix, depth + 1);
        }
    }

    private static void collectComplement(
            TrieNode node,
            byte[] network,
            int depth,
            int bitCount,
            ArrayList<Prefix> result) {
        if (result.size() > MAX_COMPLEMENT_ROUTES) {
            throw new IllegalArgumentException("Proxy route complement exceeds the safe bound.");
        }
        if (node == null) {
            result.add(new Prefix(masked(network, depth), depth));
            return;
        }
        if (node.excluded) {
            return;
        }
        if (depth >= bitCount) {
            result.add(new Prefix(masked(network, depth), depth));
            return;
        }

        byte[] zeroNetwork = network.clone();
        setBit(zeroNetwork, depth, false);
        collectComplement(node.zero, zeroNetwork, depth + 1, bitCount, result);

        byte[] oneNetwork = network.clone();
        setBit(oneNetwork, depth, true);
        collectComplement(node.one, oneNetwork, depth + 1, bitCount, result);
    }

    private static boolean contains(Prefix outer, Prefix inner) {
        if (outer.network.length != inner.network.length || outer.length > inner.length) {
            return false;
        }
        for (int index = 0; index < outer.length; index++) {
            if (bit(outer.network, index) != bit(inner.network, index)) {
                return false;
            }
        }
        return true;
    }

    private static int bit(byte[] value, int index) {
        return ((value[index / 8] & 0xff) >>> (7 - (index % 8))) & 1;
    }

    private static void setBit(byte[] value, int index, boolean enabled) {
        int byteIndex = index / 8;
        int mask = 1 << (7 - (index % 8));
        if (enabled) {
            value[byteIndex] = (byte) ((value[byteIndex] & 0xff) | mask);
        } else {
            value[byteIndex] = (byte) ((value[byteIndex] & 0xff) & ~mask);
        }
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
                result[index] = (byte) ((result[index] & 0xff) & (0xff << (8 - remaining)));
                remaining = 0;
            }
        }
        return result;
    }

    private static void addRoute(VpnService.Builder builder, byte[] bytes, int prefix) {
        builder.addRoute(toInetAddress(bytes), prefix);
    }

    private static InetAddress toInetAddress(byte[] bytes) {
        try {
            return InetAddress.getByAddress(bytes);
        } catch (UnknownHostException impossible) {
            throw new IllegalArgumentException("VPN route address family is invalid.");
        }
    }

    private static List<Prefix> immutableCopy(List<Prefix> source) {
        ArrayList<Prefix> copy = new ArrayList<Prefix>();
        for (Prefix prefix : source) {
            copy.add(new Prefix(prefix.network, prefix.length));
        }
        return Collections.unmodifiableList(copy);
    }

    private static final class Prefix {
        final byte[] network;
        final int length;

        Prefix(byte[] network, int length) {
            this.network = network.clone();
            this.length = length;
        }
    }

    private static final class TrieNode {
        boolean excluded;
        TrieNode zero;
        TrieNode one;
    }
}
