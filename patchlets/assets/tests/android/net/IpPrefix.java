package android.net;

import java.net.InetAddress;

/** Minimal host-test IpPrefix surface used by ProxyRoutePlanner. */
public final class IpPrefix {
    private final InetAddress address;
    private final int prefixLength;

    public IpPrefix(InetAddress address, int prefixLength) {
        if (address == null) {
            throw new IllegalArgumentException("address");
        }
        int bits = address.getAddress().length * 8;
        if ((bits != 32 && bits != 128) || prefixLength < 0 || prefixLength > bits) {
            throw new IllegalArgumentException("prefixLength");
        }
        this.address = address;
        this.prefixLength = prefixLength;
    }

    public InetAddress getAddress() {
        return address;
    }

    public int getPrefixLength() {
        return prefixLength;
    }
}
