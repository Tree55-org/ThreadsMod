package threadsmod.proxy;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.net.VpnService;

/**
 * Settings-facing proxy lifecycle boundary.
 *
 * <p>The VPN/tunnel patchlet supplies {@link Socks5VpnService}. This class owns permission and
 * durable-config ordering and never places credentials in an Intent.</p>
 */
public final class ProxyController {
    private static volatile String localStatus = "Disabled.";

    private ProxyController() {}

    public static String status(Context context) {
        ProxyConfigStore.Snapshot snapshot = ProxyConfigStore.snapshot(context);
        try {
            if (!snapshot.valid) {
                return snapshot.persistenceUncertain
                        ? "Unprotected: proxy persistence is uncertain; direct traffic may continue until Android VPN protection is active."
                        : "Unprotected: saved proxy settings need review; direct traffic may continue until Android VPN protection is active.";
            }
            if (!snapshot.config.enabled()) {
                return "Disabled.";
            }
            String runtime = Socks5VpnService.runtimeState();
            if (Socks5VpnService.STATE_CONNECTED.equals(runtime)) {
                return "VPN routes are installed and the SOCKS5 engine thread is live; endpoint reachability is not verified.";
            }
            if (Socks5VpnService.STATE_STARTING.equals(runtime)) {
                return "Installing VPN routes and checking SOCKS5 engine liveness…";
            }
            if (Socks5VpnService.STATE_PAUSED_CONFIG.equals(runtime)) {
                return "Paused: proxy configuration needs review.";
            }
            if (Socks5VpnService.STATE_PAUSED_RESOLUTION.equals(runtime)) {
                return "Paused: the SOCKS5 server could not be resolved.";
            }
            if (Socks5VpnService.STATE_PAUSED_ROUTES.equals(runtime)) {
                return "Paused: bypass routes could not be installed safely.";
            }
            if (Socks5VpnService.STATE_PAUSED_NATIVE.equals(runtime)) {
                return "Paused: the SOCKS5 tunnel engine is unavailable.";
            }
            if (Socks5VpnService.STATE_PAUSED_GUARD_ACTIVE.equals(runtime)) {
                return "Paused: a full-route guard is active; app traffic remains blocked.";
            }
            if (Socks5VpnService.STATE_PAUSED_GUARD_RETAINED.equals(runtime)) {
                return "Paused: the prior full-route guard is retained; app traffic remains blocked.";
            }
            if (Socks5VpnService.STATE_UNPROTECTED_PRIOR_ROUTING.equals(runtime)) {
                return "Unprotected: Android refused the fresh full-route guard; prior VPN routing is retained and earlier numeric DIRECT exclusions may remain.";
            }
            if (Socks5VpnService.STATE_PAUSED_VPN.equals(runtime)) {
                return "Unprotected: Android could not establish the VPN; direct traffic may continue.";
            }
            if (Socks5VpnService.STATE_DISABLED.equals(runtime)) {
                return "Unprotected: proxy service is inactive; direct traffic may continue.";
            }
            String pending = localStatus;
            return pending.startsWith("Paused:")
                    || pending.startsWith("Unprotected:")
                    || pending.startsWith("Starting:")
                    ? pending
                    : "Unprotected: proxy service is not active; direct traffic may continue.";
        } finally {
            snapshot.clearPassword();
        }
    }

    /** Persists before requesting VPN authority or touching the runtime. */
    public static boolean requestConnect(
            Activity activity, ProxyConfig config, int requestCode) {
        if (activity == null || config == null || requestCode < 0) {
            return false;
        }
        if (!ProxyConfigStore.save(activity, config)) {
            localStatus = "Paused: proxy configuration persistence failed.";
            return false;
        }
        if (!config.enabled()) {
            disconnectRuntime(activity.getApplicationContext());
            localStatus = "Disabled.";
            return true;
        }
        final Intent approval;
        try {
            approval = VpnService.prepare(activity);
        } catch (RuntimeException unavailable) {
            localStatus = "Unprotected: Android VPN approval is unavailable; direct traffic may continue.";
            return true;
        }
        if (approval != null) {
            try {
                activity.startActivityForResult(approval, requestCode);
                localStatus = "Unprotected: waiting for Android VPN approval; direct traffic may continue.";
                return true;
            } catch (RuntimeException unavailable) {
                localStatus = "Unprotected: Android VPN approval could not be opened; direct traffic may continue.";
                return true;
            }
        }
        connectRuntime(activity.getApplicationContext());
        return true;
    }

    /** Handles only a result already selected by the private Proxy Settings activity. */
    public static boolean handleActivityResult(
            Activity activity, int requestCode, int resultCode) {
        if (activity == null || requestCode < 0) {
            return false;
        }
        if (resultCode != Activity.RESULT_OK) {
            localStatus = "Unprotected: Android VPN approval was denied; direct traffic may continue.";
            return false;
        }
        connectRuntime(activity.getApplicationContext());
        return true;
    }

    /** Atomically records disabled state before stopping the current tunnel. */
    public static boolean disconnect(Context context) {
        if (context == null) {
            return false;
        }
        ProxyConfigStore.Snapshot snapshot = ProxyConfigStore.snapshot(context);
        ProxyConfig disabled = null;
        try {
            disabled = snapshot.valid
                    ? snapshot.config.withEnabled(false) : ProxyConfig.defaults();
            if (!ProxyConfigStore.save(context, disabled)) {
                localStatus = "Paused: disabled state could not be confirmed.";
                return false;
            }
            disconnectRuntime(context.getApplicationContext());
            localStatus = "Disabled.";
            return true;
        } finally {
            if (disabled != null) {
                disabled.clearPassword();
            }
            snapshot.clearPassword();
        }
    }

    private static void connectRuntime(Context context) {
        try {
            Socks5VpnService.requestConnect(context);
            localStatus = "Starting: VPN service requested; protection begins when Android establishes it.";
        } catch (RuntimeException unavailable) {
            localStatus = "Unprotected: proxy service could not start; direct traffic may continue.";
        }
    }

    private static void disconnectRuntime(Context context) {
        try {
            Socks5VpnService.requestDisconnect(context);
        } catch (RuntimeException ignored) {
            // Durable disabled state is authoritative; runtime teardown remains best effort here.
        }
    }
}
