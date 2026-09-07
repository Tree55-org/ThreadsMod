package threadsmod.proxy;

import android.net.IpPrefix;
import android.net.VpnService;
import android.os.Build;

import java.net.InetAddress;
import java.util.List;

/** Host-JVM checks that native exclusions and legacy complements implement the same policy. */
public final class ProxyRoutePlannerHarness {
    private ProxyRoutePlannerHarness() {}

    public static void main(String[] args) throws Exception {
        ProxyBypassPolicy policy = ProxyBypassPolicy.parse(
                "10.0.0.0/8\n2001:db8::/32");
        InetAddress[] endpoints = new InetAddress[] {
            numeric("198.51.100.10"), numeric("2001:db9::1")
        };

        verifyApi33Exclusions(policy, endpoints);
        verifyLegacyComplement(policy, endpoints);
        verifyBounds(policy);
        System.out.println(
                "PASS proxy-routes api33=true legacy=true equivalence=true "
                + "bounded=true exclusions=4");
    }

    private static void verifyApi33Exclusions(
            ProxyBypassPolicy policy, InetAddress[] endpoints) throws Exception {
        Build.VERSION.SDK_INT = 33;
        ProxyRoutePlanner.Plan plan = ProxyRoutePlanner.create(policy, endpoints);
        require(plan.exclusionCount() == 4, "API 33 normalized exclusion count");
        require(plan.legacyRouteCount() == 0, "API 33 has no complement routes");

        VpnService.Builder builder = new VpnService.Builder();
        plan.apply(builder);
        require(builder.routes().size() == 2, "API 33 has two family default routes");
        require(containsExactRoute(builder.routes(), "0.0.0.0", 0),
                "API 33 IPv4 default route");
        require(containsExactRoute(builder.routes(), "::", 0),
                "API 33 IPv6 default route");
        require(builder.exclusions().size() == 4, "API 33 applies every exclusion");
        require(containsExactPrefix(builder.exclusions(), "10.0.0.0", 8),
                "API 33 IPv4 user exclusion");
        require(containsExactPrefix(builder.exclusions(), "2001:db8::", 32),
                "API 33 IPv6 user exclusion");
        require(containsExactPrefix(builder.exclusions(), "198.51.100.10", 32),
                "API 33 IPv4 SOCKS endpoint exclusion");
        require(containsExactPrefix(builder.exclusions(), "2001:db9::1", 128),
                "API 33 IPv6 SOCKS endpoint exclusion");
    }

    private static void verifyLegacyComplement(
            ProxyBypassPolicy policy, InetAddress[] endpoints) throws Exception {
        Build.VERSION.SDK_INT = 32;
        ProxyRoutePlanner.Plan plan = ProxyRoutePlanner.create(policy, endpoints);
        require(plan.exclusionCount() == 4, "legacy normalized exclusion count");
        require(plan.legacyRouteCount() > 2, "legacy complement is nontrivial");
        require(plan.legacyRouteCount() <= ProxyRoutePlanner.MAX_COMPLEMENT_ROUTES,
                "legacy route count bounded");

        VpnService.Builder builder = new VpnService.Builder();
        plan.apply(builder);
        require(builder.exclusions().isEmpty(), "legacy API uses no exclusion method");
        require(builder.routes().size() == plan.legacyRouteCount(),
                "legacy plan count equals applied routes");

        require(!isCovered(builder.routes(), numeric("10.1.2.3")),
                "legacy IPv4 user bypass stays DIRECT");
        require(!isCovered(builder.routes(), numeric("198.51.100.10")),
                "legacy IPv4 SOCKS endpoint stays DIRECT");
        require(!isCovered(builder.routes(), numeric("2001:db8::1234")),
                "legacy IPv6 user bypass stays DIRECT");
        require(!isCovered(builder.routes(), numeric("2001:db9::1")),
                "legacy IPv6 SOCKS endpoint stays DIRECT");
        require(isCovered(builder.routes(), numeric("8.8.8.8")),
                "legacy ordinary IPv4 stays in VPN");
        require(isCovered(builder.routes(), numeric("2001:4860:4860::8888")),
                "legacy ordinary IPv6 stays in VPN");
    }

    private static void verifyBounds(ProxyBypassPolicy basePolicy) throws Exception {
        Build.VERSION.SDK_INT = 33;
        expectInvalid(null, new InetAddress[] {numeric("192.0.2.1")},
                "missing bypass policy");
        expectInvalid(basePolicy, null, "missing endpoint list");
        expectInvalid(basePolicy, new InetAddress[0], "empty endpoint list");
        expectInvalid(basePolicy, new InetAddress[] {null}, "null endpoint");

        InetAddress[] tooManyEndpoints = new InetAddress[17];
        for (int index = 0; index < tooManyEndpoints.length; index++) {
            tooManyEndpoints[index] = numeric("198.51.100." + (index + 1));
        }
        expectInvalid(basePolicy, tooManyEndpoints, "17 endpoint addresses");

        StringBuilder maximumRules = new StringBuilder();
        for (int index = 0; index < 64; index++) {
            if (index > 0) {
                maximumRules.append('\n');
            }
            maximumRules.append("10.0.0.").append(index);
        }
        InetAddress[] maximumEndpoints = new InetAddress[16];
        for (int index = 0; index < maximumEndpoints.length; index++) {
            maximumEndpoints[index] = numeric("198.51.100." + (index + 1));
        }
        ProxyRoutePlanner.Plan maximum = ProxyRoutePlanner.create(
                ProxyBypassPolicy.parse(maximumRules.toString()), maximumEndpoints);
        require(maximum.exclusionCount() <= ProxyRoutePlanner.MAX_EXCLUDED_PREFIXES,
                "80 raw exclusions remain within fixed bound");
    }

    private static boolean containsExactRoute(
            List<VpnService.Builder.Route> routes, String address, int prefix) throws Exception {
        byte[] expected = numeric(address).getAddress();
        for (VpnService.Builder.Route route : routes) {
            if (route.prefixLength() == prefix
                    && bytesEqual(route.address().getAddress(), expected)) {
                return true;
            }
        }
        return false;
    }

    private static boolean containsExactPrefix(
            List<IpPrefix> prefixes, String address, int prefix) throws Exception {
        byte[] expected = numeric(address).getAddress();
        for (IpPrefix candidate : prefixes) {
            if (candidate.getPrefixLength() == prefix
                    && bytesEqual(candidate.getAddress().getAddress(), expected)) {
                return true;
            }
        }
        return false;
    }

    private static boolean isCovered(
            List<VpnService.Builder.Route> routes, InetAddress destination) {
        byte[] target = destination.getAddress();
        for (VpnService.Builder.Route route : routes) {
            byte[] network = route.address().getAddress();
            if (network.length == target.length
                    && prefixMatches(network, target, route.prefixLength())) {
                return true;
            }
        }
        return false;
    }

    private static boolean prefixMatches(byte[] network, byte[] target, int prefix) {
        int fullBytes = prefix / 8;
        int remaining = prefix % 8;
        for (int index = 0; index < fullBytes; index++) {
            if (network[index] != target[index]) {
                return false;
            }
        }
        if (remaining == 0) {
            return true;
        }
        int mask = 0xff << (8 - remaining);
        return ((network[fullBytes] & 0xff) & mask)
                == ((target[fullBytes] & 0xff) & mask);
    }

    private static boolean bytesEqual(byte[] left, byte[] right) {
        if (left.length != right.length) {
            return false;
        }
        for (int index = 0; index < left.length; index++) {
            if (left[index] != right[index]) {
                return false;
            }
        }
        return true;
    }

    private static InetAddress numeric(String value) throws Exception {
        return InetAddress.getByName(value);
    }

    private static void expectInvalid(
            ProxyBypassPolicy policy, InetAddress[] endpoints, String label) {
        try {
            ProxyRoutePlanner.create(policy, endpoints);
            throw new AssertionError("invalid route inputs were accepted: " + label);
        } catch (IllegalArgumentException expected) {
            // Expected fail-closed validation.
        }
    }

    private static void require(boolean value, String label) {
        if (!value) {
            throw new AssertionError(label);
        }
    }
}
