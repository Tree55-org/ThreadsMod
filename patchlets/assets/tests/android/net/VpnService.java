package android.net;

import java.net.InetAddress;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Minimal recording host-test VpnService surface used by ProxyRoutePlanner. */
public class VpnService {
    public static class Builder {
        private final ArrayList<Route> routes = new ArrayList<Route>();
        private final ArrayList<IpPrefix> exclusions = new ArrayList<IpPrefix>();

        public Builder addRoute(InetAddress address, int prefixLength) {
            routes.add(new Route(address, prefixLength));
            return this;
        }

        public Builder excludeRoute(IpPrefix prefix) {
            if (prefix == null) {
                throw new IllegalArgumentException("prefix");
            }
            exclusions.add(prefix);
            return this;
        }

        public List<Route> routes() {
            return Collections.unmodifiableList(routes);
        }

        public List<IpPrefix> exclusions() {
            return Collections.unmodifiableList(exclusions);
        }

        public static final class Route {
            private final InetAddress address;
            private final int prefixLength;

            Route(InetAddress address, int prefixLength) {
                if (address == null) {
                    throw new IllegalArgumentException("address");
                }
                int bits = address.getAddress().length * 8;
                if ((bits != 32 && bits != 128)
                        || prefixLength < 0 || prefixLength > bits) {
                    throw new IllegalArgumentException("prefixLength");
                }
                this.address = address;
                this.prefixLength = prefixLength;
            }

            public InetAddress address() {
                return address;
            }

            public int prefixLength() {
                return prefixLength;
            }
        }
    }
}
