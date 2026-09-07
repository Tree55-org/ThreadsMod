package threadsmod.proxy;

import android.content.Context;
import android.content.Intent;
import android.net.VpnService;

import java.util.concurrent.atomic.AtomicBoolean;

/** Early, credential-free process hook for restoring a previously approved enabled VPN. */
public final class ProxyBootstrap {
    private static final AtomicBoolean ATTACHED = new AtomicBoolean();

    private ProxyBootstrap() {}

    /**
     * Called from the exact-SHA Application attachBaseContext rewrite.
     *
     * <p>The missing-state default is disabled and starts nothing. This hook never opens consent
     * UI; Settings owns that explicit user interaction. When consent already exists, an enabled or
     * corrupt-enabled snapshot is delegated to the service, which either connects or installs its
     * fail-closed blackhole.</p>
     */
    public static void install(Context context) {
        if (context == null || !ATTACHED.compareAndSet(false, true)) {
            return;
        }
        Context application = context.getApplicationContext();
        Context owner = application == null ? context : application;
        ProxyConfigStore.Snapshot snapshot = ProxyConfigStore.snapshot(owner);
        try {
            if (!snapshot.enabledRequested) {
                return;
            }
            Intent consent;
            try {
                consent = VpnService.prepare(owner);
            } catch (RuntimeException unavailable) {
                return;
            }
            if (consent != null) {
                return;
            }
            try {
                Socks5VpnService.requestConnect(owner);
            } catch (RuntimeException unavailable) {
                // The durable enabled request remains for Settings or a later foreground attach.
            }
        } finally {
            snapshot.clearPassword();
        }
    }
}
