package threadsmod.proxy;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;

import java.io.IOException;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * App-scoped SOCKS5 VPN runtime.
 *
 * <p>No configuration or credential is accepted through an Intent. CONNECT always reloads the
 * atomically persisted snapshot, synchronously installs a full-route guard before resolving the
 * SOCKS infrastructure, and passes an in-memory YAML document to the pinned JNI adapter. Any
 * invalid enabled state or startup failure is replaced with a full-route TUN that has no packet
 * consumer.</p>
 */
public final class Socks5VpnService extends VpnService {
    public static final String ACTION_CONNECT = "threadsmod.proxy.action.CONNECT";
    public static final String ACTION_DISCONNECT = "threadsmod.proxy.action.DISCONNECT";

    public static final String STATE_DISABLED = "disabled";
    public static final String STATE_STARTING = "starting";
    public static final String STATE_CONNECTED = "connected";
    public static final String STATE_PAUSED_CONFIG = "paused_config";
    public static final String STATE_PAUSED_RESOLUTION = "paused_resolution";
    public static final String STATE_PAUSED_ROUTES = "paused_routes";
    public static final String STATE_PAUSED_NATIVE = "paused_native";
    public static final String STATE_PAUSED_VPN = "paused_vpn";
    public static final String STATE_PAUSED_GUARD_ACTIVE = "paused_guard_active";
    public static final String STATE_PAUSED_GUARD_RETAINED = "paused_guard_retained";
    public static final String STATE_UNPROTECTED_PRIOR_ROUTING = "unprotected_prior_routing";

    private static final String CHANNEL_ID = "threadsmod_proxy_status_v1";
    private static final int NOTIFICATION_ID = 0x54505258;
    private static final int DISCONNECT_REQUEST_CODE = 0x5450;
    private static final int MTU = 8500;
    private static final int MAX_RESOLVED_ENDPOINTS = 16;
    private static final int MAX_DIRECT_NETWORKS = 8;
    private static final int MAX_DNS_SERVERS = 8;
    private static final long LIVENESS_CHECK_MILLIS = 500L;

    private static final String TUN_IPV4 = "198.18.0.1";
    private static final String TUN_IPV6 = "fc00::1";
    private static final String BLACKHOLE_DNS_IPV4 = "198.18.0.2";
    private static final String BLACKHOLE_DNS_IPV6 = "fc00::2";

    private static final Object ENGINE_LOCK = new Object();
    private static boolean nativeLoadAttempted;
    private static boolean nativeLoaded;
    private static boolean nativeLifecycleUncertain;
    private static Socks5VpnService activeInstance;
    /** Keeps an unjoined native worker's descriptor number from being reused in this process. */
    private static final ArrayList<ParcelFileDescriptor> RETAINED_NATIVE_TUNS =
            new ArrayList<ParcelFileDescriptor>();
    private static volatile String runtimeState = STATE_DISABLED;

    private final AtomicInteger requestGeneration = new AtomicInteger();
    private final ScheduledExecutorService worker =
            Executors.newSingleThreadScheduledExecutor(new ThreadFactory() {
        @Override
        public Thread newThread(Runnable runnable) {
            Thread thread = new Thread(runnable, "threadsmod-proxy-runtime");
            thread.setDaemon(true);
            return thread;
        }
    });

    private ParcelFileDescriptor activeTun;
    private ParcelFileDescriptor nativeTun;
    private boolean activeTunIsGuard;
    private boolean nativeActive;

    private static native boolean TProxyStartService(String configText, int fd);
    private static native boolean TProxyStopService();
    private static native boolean TProxyIsRunning();
    private static native long[] TProxyGetStats();

    public static void requestConnect(Context context) {
        startAction(context, ACTION_CONNECT);
    }

    public static void requestDisconnect(Context context) {
        startAction(context, ACTION_DISCONNECT);
    }

    /** Returns a credential-free process-local status token suitable for Settings UI. */
    public static String runtimeState() {
        Socks5VpnService owner = null;
        int generation = 0;
        if (STATE_CONNECTED.equals(runtimeState)) {
            synchronized (ENGINE_LOCK) {
                try {
                    if (!nativeLoaded || nativeLifecycleUncertain || !TProxyIsRunning()) {
                        owner = activeInstance;
                        if (owner != null) {
                            owner.nativeActive = false;
                            generation = owner.requestGeneration.get();
                        } else {
                            runtimeState = STATE_PAUSED_NATIVE;
                        }
                    }
                } catch (Throwable nativeFailure) {
                    owner = activeInstance;
                    if (owner != null) {
                        owner.nativeActive = false;
                        generation = owner.requestGeneration.get();
                    } else {
                        runtimeState = STATE_PAUSED_NATIVE;
                    }
                }
            }
        }
        if (owner != null) {
            owner.enterBlackhole(generation, STATE_PAUSED_NATIVE);
        }
        return runtimeState;
    }

    /** Returns only the four native packet/byte counters, or zeroes when unavailable. */
    public static long[] statsSnapshot() {
        synchronized (ENGINE_LOCK) {
            if (!nativeLoaded || nativeLifecycleUncertain) {
                return new long[] {0L, 0L, 0L, 0L};
            }
            try {
                if (!TProxyIsRunning()) {
                    return new long[] {0L, 0L, 0L, 0L};
                }
                long[] raw = TProxyGetStats();
                if (raw == null || raw.length != 4) {
                    return new long[] {0L, 0L, 0L, 0L};
                }
                long[] safe = raw.clone();
                for (int index = 0; index < safe.length; index++) {
                    if (safe[index] < 0L) {
                        safe[index] = 0L;
                    }
                }
                return safe;
            } catch (Throwable nativeFailure) {
                return new long[] {0L, 0L, 0L, 0L};
            }
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        synchronized (ENGINE_LOCK) {
            activeInstance = this;
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        ensureForeground("Starting proxy protection");

        String action = intent == null ? ACTION_CONNECT : intent.getAction();
        final int generation;
        synchronized (ENGINE_LOCK) {
            // Request invalidation is serialized with every TUN/native transition so a newer
            // action cannot strand a just-established interface or stop its successor.
            generation = requestGeneration.incrementAndGet();
        }
        if (ACTION_DISCONNECT.equals(action)) {
            submit(new Runnable() {
                @Override
                public void run() {
                    disconnectNow(generation, startId);
                }
            }, generation, false);
            return START_NOT_STICKY;
        }
        if (!ACTION_CONNECT.equals(action)) {
            enterBlackhole(generation, STATE_PAUSED_CONFIG);
            return START_STICKY;
        }

        if (!ensureConnectGuard(generation)) {
            return START_STICKY;
        }
        setRuntimeState(STATE_STARTING, "Starting proxy protection");
        submit(new Runnable() {
            @Override
            public void run() {
                connectFromStore(generation, startId);
            }
        }, generation, true);
        return START_STICKY;
    }

    @Override
    public void onRevoke() {
        synchronized (ENGINE_LOCK) {
            requestGeneration.incrementAndGet();
            stopEngineAndTunLocked();
        }
        runtimeState = STATE_DISABLED;
        stopForeground(true);
        stopSelf();
        super.onRevoke();
    }

    @Override
    public void onDestroy() {
        synchronized (ENGINE_LOCK) {
            requestGeneration.incrementAndGet();
            stopEngineAndTunLocked();
            if (activeInstance == this) {
                activeInstance = null;
            }
        }
        worker.shutdownNow();
        runtimeState = STATE_DISABLED;
        super.onDestroy();
    }

    private void submit(Runnable task, int generation, boolean failClosedOnReject) {
        try {
            worker.execute(task);
        } catch (RejectedExecutionException rejected) {
            if (failClosedOnReject && isCurrent(generation)) {
                enterBlackhole(generation, STATE_PAUSED_VPN);
            }
        }
    }

    private void connectFromStore(int generation, int startId) {
        if (!isCurrent(generation)) {
            return;
        }
        ProxyConfigStore.Snapshot snapshot = ProxyConfigStore.snapshot(this);
        try {
            if (!isCurrent(generation)) {
                return;
            }
            if (!snapshot.enabledRequested) {
                disconnectNow(generation, startId);
                return;
            }
            if (!snapshot.valid || snapshot.persistenceUncertain || snapshot.config == null
                    || !snapshot.config.enabled()) {
                enterBlackhole(generation, STATE_PAUSED_CONFIG);
                return;
            }
            connectValidated(snapshot.config, generation);
        } finally {
            snapshot.clearPassword();
        }
    }

    private void connectValidated(ProxyConfig config, int generation) {
        if (!isCurrent(generation)) {
            return;
        }
        final ResolvedInfrastructure infrastructure;
        try {
            infrastructure = resolveInfrastructure(config.host());
        } catch (Exception resolutionFailure) {
            enterBlackhole(generation, STATE_PAUSED_RESOLUTION);
            return;
        }
        if (!isCurrent(generation)) {
            return;
        }
        if (containsAddress(
                infrastructure.dnsServers, infrastructure.endpointAddresses[0])) {
            // The endpoint's mandatory IP-wide DIRECT route would also make DNS to the same
            // address bypass the tunnel. Keep the full-route guard instead of leaking queries.
            enterBlackhole(generation, STATE_PAUSED_ROUTES);
            return;
        }

        final ProxyRoutePlanner.Plan routePlan;
        try {
            // Native receives the first, system-preferred numeric result, so only that exact
            // address is mandatory DIRECT infrastructure. Excluding unused answers would widen
            // the app's direct route surface without helping the active tunnel.
            routePlan = ProxyRoutePlanner.create(
                    config.bypassPolicy(),
                    new InetAddress[] {infrastructure.endpointAddresses[0]});
        } catch (RuntimeException invalidPlan) {
            enterBlackhole(generation, STATE_PAUSED_ROUTES);
            return;
        }
        if (!isCurrent(generation)) {
            return;
        }

        String numericEndpoint = canonicalAddress(infrastructure.endpointAddresses[0]);
        String yaml = buildInMemoryYaml(config, numericEndpoint);
        boolean established = false;
        boolean started = false;
        synchronized (ENGINE_LOCK) {
            if (!isCurrent(generation)) {
                yaml = null;
                return;
            }
            // Keep the existing forwarding/blackhole interface alive until Android has accepted
            // the replacement. Once established, the candidate itself blocks every route except
            // the reviewed numeric DIRECT exclusions while native startup is still in progress.
            ParcelFileDescriptor candidate = establishTun(routePlan, infrastructure.dnsServers);
            if (candidate != null) {
                established = true;
                started = adoptAndStartLocked(candidate, yaml);
                if (!started) {
                    // Replace the forwarding route set before releasing ENGINE_LOCK. This removes
                    // user and endpoint DIRECT exclusions immediately on a synchronous failure.
                    enterBlackhole(generation, STATE_PAUSED_NATIVE);
                }
            }
        }
        yaml = null;
        if (!established) {
            enterBlackhole(generation, STATE_PAUSED_VPN);
            return;
        }
        if (!started || !confirmNativeStartup(generation)) {
            if (!isCurrent(generation)) {
                return;
            }
            if (started) {
                enterBlackhole(generation, STATE_PAUSED_NATIVE);
            }
            return;
        }
        synchronized (ENGINE_LOCK) {
            if (!isCurrent(generation)) {
                return;
            }
            setRuntimeState(
                    STATE_CONNECTED,
                    "VPN routes + SOCKS5 worker live; endpoint unverified");
        }
        if (!scheduleLivenessCheck(generation)) {
            enterBlackhole(generation, STATE_PAUSED_NATIVE);
        }
    }

    /** The JNI start result means its worker was created; require a short stable running window. */
    private boolean confirmNativeStartup(int generation) {
        for (int attempt = 0; attempt < 5; attempt++) {
            try {
                Thread.sleep(50L);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return false;
            }
            synchronized (ENGINE_LOCK) {
                if (!isCurrent(generation)) {
                    return false;
                }
                try {
                    if (!nativeLoaded || nativeLifecycleUncertain
                            || !nativeActive || !TProxyIsRunning()) {
                        return false;
                    }
                } catch (Throwable nativeFailure) {
                    return false;
                }
            }
        }
        return true;
    }

    private boolean scheduleLivenessCheck(final int generation) {
        try {
            worker.schedule(new Runnable() {
                @Override
                public void run() {
                    checkNativeLiveness(generation);
                }
            }, LIVENESS_CHECK_MILLIS, TimeUnit.MILLISECONDS);
            return true;
        } catch (RejectedExecutionException rejected) {
            return false;
        }
    }

    private void checkNativeLiveness(int generation) {
        boolean alive;
        synchronized (ENGINE_LOCK) {
            if (!isCurrent(generation) || activeTun == null || activeTunIsGuard) {
                return;
            }
            try {
                alive = !nativeLifecycleUncertain
                        && nativeActive
                        && TProxyIsRunning();
            } catch (Throwable nativeFailure) {
                alive = false;
            }
            if (!alive) {
                nativeActive = false;
            }
        }
        if (!alive) {
            enterBlackhole(generation, STATE_PAUSED_NATIVE);
            return;
        }
        if (!scheduleLivenessCheck(generation)) {
            enterBlackhole(generation, STATE_PAUSED_NATIVE);
        }
    }

    private void disconnectNow(int generation, int startId) {
        synchronized (ENGINE_LOCK) {
            if (!isCurrent(generation)) {
                return;
            }
            // Do not let a delayed DISCONNECT tear down a newer start that Android has already
            // accepted but whose onStartCommand has not yet acquired ENGINE_LOCK.
            if (!stopSelfResult(startId)) {
                return;
            }
            stopEngineAndTunLocked();
            runtimeState = STATE_DISABLED;
            stopForeground(true);
        }
    }

    /** Installs the synchronous no-consumer guard required before any CONNECT worker can run. */
    private boolean ensureConnectGuard(int generation) {
        synchronized (ENGINE_LOCK) {
            if (!isCurrent(generation)) {
                return false;
            }
            // Every CONNECT gets a fresh full-route guard. Reusing an existing forwarding TUN
            // would leave its prior user DIRECT exclusions active while the new endpoint/config
            // is resolved. Establish first so failure retains the previous protected interface.
            ParcelFileDescriptor candidate = establishBlackholeTun();
            if (candidate == null) {
                if (activeTun != null && activeTunIsGuard) {
                    setRuntimeState(
                            STATE_PAUSED_GUARD_RETAINED,
                            "Traffic remains paused; prior full-route guard retained");
                } else if (activeTun != null) {
                    setRuntimeState(
                            STATE_UNPROTECTED_PRIOR_ROUTING,
                            "Prior VPN routing retained; earlier numeric DIRECT exclusions may remain");
                } else {
                    setRuntimeState(
                            STATE_PAUSED_VPN,
                            "VPN guard unavailable; direct traffic may continue");
                }
                return false;
            }
            if (!adoptBlackholeCandidateLocked(candidate)) {
                setRuntimeState(
                        STATE_PAUSED_NATIVE,
                        "Traffic paused; native shutdown unconfirmed");
                return false;
            }
            return true;
        }
    }

    private boolean enterBlackhole(int generation, String state) {
        synchronized (ENGINE_LOCK) {
            if (!isCurrent(generation)) {
                return false;
            }
            // Establish first: failure retains the previous protected interface rather than
            // creating a direct-traffic window while handling an already enabled request.
            ParcelFileDescriptor candidate = establishBlackholeTun();
            if (candidate == null) {
                if (activeTun != null && activeTunIsGuard) {
                    String retainedState = STATE_PAUSED_VPN.equals(state)
                            ? STATE_PAUSED_GUARD_RETAINED : state;
                    setRuntimeState(
                            retainedState,
                            STATE_PAUSED_GUARD_RETAINED.equals(retainedState)
                                    ? "Traffic remains paused; prior full-route guard retained"
                                    : "Traffic remains paused for safety");
                    return true;
                }
                if (activeTun != null) {
                    setRuntimeState(
                            STATE_UNPROTECTED_PRIOR_ROUTING,
                            "Prior VPN routing retained; earlier numeric DIRECT exclusions may remain");
                    return false;
                }
                setRuntimeState(
                        STATE_PAUSED_VPN,
                        "VPN guard unavailable; direct traffic may continue");
                return false;
            }
            if (!adoptBlackholeCandidateLocked(candidate)) {
                setRuntimeState(
                        STATE_PAUSED_NATIVE,
                        "Traffic paused; native shutdown unconfirmed");
                return true;
            }
            String activeState = STATE_PAUSED_VPN.equals(state)
                    ? STATE_PAUSED_GUARD_ACTIVE : state;
            setRuntimeState(
                    activeState,
                    STATE_PAUSED_GUARD_ACTIVE.equals(activeState)
                            ? "Traffic paused; full-route guard active"
                            : "Traffic paused for safety");
            return true;
        }
    }

    /** Installs an already-established full-route guard without recycling an unjoined native FD. */
    private boolean adoptBlackholeCandidateLocked(ParcelFileDescriptor candidate) {
        ParcelFileDescriptor previous = activeTun;
        ParcelFileDescriptor nativeOwned = nativeTun;
        boolean stopped = stopNativeLocked();

        activeTun = candidate;
        activeTunIsGuard = true;
        nativeActive = false;
        if (stopped) {
            closeQuietly(previous);
            nativeTun = null;
            return true;
        }

        retainNativeTunLocked(nativeOwned);
        if (previous != nativeOwned) {
            closeQuietly(previous);
        }
        nativeTun = null;
        return false;
    }

    private ParcelFileDescriptor establishTun(
            ProxyRoutePlanner.Plan routePlan, InetAddress[] dnsServers) {
        try {
            Builder builder = baseBuilder();
            if (dnsServers == null || dnsServers.length == 0
                    || dnsServers.length > MAX_DNS_SERVERS) {
                return null;
            }
            for (InetAddress dnsServer : dnsServers) {
                builder.addDnsServer(dnsServer);
            }
            routePlan.apply(builder);
            return builder.establish();
        } catch (Exception establishFailure) {
            return null;
        }
    }

    private ParcelFileDescriptor establishBlackholeTun() {
        try {
            Builder builder = baseBuilder();
            builder.addDnsServer(BLACKHOLE_DNS_IPV4);
            builder.addDnsServer(BLACKHOLE_DNS_IPV6);
            builder.addRoute("0.0.0.0", 0);
            builder.addRoute("::", 0);
            return builder.establish();
        } catch (Exception establishFailure) {
            return null;
        }
    }

    private Builder baseBuilder() throws PackageManager.NameNotFoundException {
        Builder builder = new Builder();
        builder.setSession("Threads Mod SOCKS5");
        builder.setMtu(MTU);
        builder.addAddress(TUN_IPV4, 32);
        builder.addAddress(TUN_IPV6, 128);
        builder.addAllowedApplication(getPackageName());
        return builder;
    }

    /** Caller must hold ENGINE_LOCK and must have established candidate before replacing active. */
    private boolean adoptAndStartLocked(ParcelFileDescriptor candidate, String yaml) {
        ParcelFileDescriptor previous = activeTun;
        ParcelFileDescriptor nativeOwned = nativeTun;
        if (!stopNativeLocked()) {
            retainNativeTunLocked(nativeOwned);
            if (previous != nativeOwned) {
                closeQuietly(previous);
            }
            activeTun = candidate;
            activeTunIsGuard = false;
            nativeTun = null;
            nativeActive = false;
            return false;
        }
        closeQuietly(previous);
        activeTun = candidate;
        activeTunIsGuard = false;
        nativeActive = false;
        if (!ensureNativeLoadedLocked()) {
            return false;
        }
        try {
            // Mark descriptor ownership before JNI; a thrown call is conservatively treated as
            // possibly started until the native stop/join result proves otherwise.
            nativeTun = candidate;
            boolean started = TProxyStartService(yaml, candidate.getFd());
            nativeActive = started && TProxyIsRunning();
            if (!nativeActive) {
                stopNativeLocked();
            }
            return nativeActive;
        } catch (Throwable nativeFailure) {
            stopNativeLocked();
            nativeActive = false;
            return false;
        }
    }

    /** Caller must hold ENGINE_LOCK. */
    private void stopEngineAndTunLocked() {
        ParcelFileDescriptor previous = activeTun;
        ParcelFileDescriptor nativeOwned = nativeTun;
        boolean stopped = stopNativeLocked();
        if (stopped) {
            closeQuietly(previous);
        } else {
            retainNativeTunLocked(nativeOwned);
            if (previous != nativeOwned) {
                closeQuietly(previous);
            }
        }
        activeTun = null;
        activeTunIsGuard = false;
        nativeTun = null;
    }

    /** Returns true only when native confirms its worker is stopped and joined. */
    private boolean stopNativeLocked() {
        if (!nativeLoaded) {
            nativeActive = false;
            nativeTun = null;
            return true;
        }
        if (nativeLifecycleUncertain) {
            nativeActive = false;
            return false;
        }
        final boolean stopped;
        try {
            // Always call: an exited native worker can remain joinable after isRunning becomes
            // false, and the Java owner must not recycle its descriptor before that join.
            stopped = TProxyStopService();
        } catch (Throwable stopFailure) {
            nativeLifecycleUncertain = true;
            nativeActive = false;
            return false;
        }
        if (!stopped) {
            nativeLifecycleUncertain = true;
            nativeActive = false;
            return false;
        }
        nativeActive = false;
        nativeTun = null;
        return true;
    }

    /** Retained for process lifetime so an unjoined worker can never observe FD-number reuse. */
    private static void retainNativeTunLocked(ParcelFileDescriptor descriptor) {
        if (descriptor != null && !RETAINED_NATIVE_TUNS.contains(descriptor)) {
            RETAINED_NATIVE_TUNS.add(descriptor);
        }
    }

    private static boolean ensureNativeLoadedLocked() {
        if (nativeLifecycleUncertain) {
            return false;
        }
        if (nativeLoadAttempted) {
            return nativeLoaded;
        }
        nativeLoadAttempted = true;
        try {
            System.loadLibrary("hev-socks5-tunnel");
            nativeLoaded = true;
        } catch (Throwable loadFailure) {
            nativeLoaded = false;
        }
        return nativeLoaded;
    }

    private ResolvedInfrastructure resolveInfrastructure(String host) throws Exception {
        ProxyBypassPolicy.AddressValue numeric = null;
        try {
            numeric = ProxyBypassPolicy.parseNumericAddress(host);
        } catch (IllegalArgumentException notNumeric) {
            // Hostnames are resolved below on a specifically selected non-VPN network.
        }
        ConnectivityManager manager = (ConnectivityManager)
                getSystemService(Context.CONNECTIVITY_SERVICE);
        if (manager == null) {
            throw new IllegalArgumentException(
                    "Direct SOCKS5 infrastructure resolution is unavailable.");
        }

        ArrayList<Network> directNetworks = directNetworks(manager);
        for (Network network : directNetworks) {
            try {
                InetAddress[] dnsServers = captureDnsServers(manager, network);
                if (dnsServers.length == 0) {
                    continue;
                }
                InetAddress[] endpoints = numeric == null
                        ? sanitizeResolved(network.getAllByName(host))
                        : new InetAddress[] {InetAddress.getByAddress(numeric.bytes)};
                if (endpoints.length > 0) {
                    return new ResolvedInfrastructure(endpoints, dnsServers);
                }
            } catch (Exception unavailable) {
                // Try the next bounded non-VPN network without rendering the host or error.
            }
        }
        throw new IllegalArgumentException(
                "Direct SOCKS5 infrastructure resolution is unavailable.");
    }

    private static ArrayList<Network> directNetworks(ConnectivityManager manager) {
        ArrayList<Network> result = new ArrayList<Network>();
        Network active = manager.getActiveNetwork();
        NetworkCapabilities activeCapabilities = active == null
                ? null : manager.getNetworkCapabilities(active);
        if (active != null && isDirectInternet(activeCapabilities)) {
            addDirectNetwork(result, active);
        }

        Network[] available = manager.getAllNetworks();
        for (int pass = 0; pass < 2 && result.size() < MAX_DIRECT_NETWORKS; pass++) {
            for (Network network : available) {
                if (network == null || result.size() >= MAX_DIRECT_NETWORKS) {
                    continue;
                }
                NetworkCapabilities capabilities = manager.getNetworkCapabilities(network);
                if (!isDirectInternet(capabilities)) {
                    continue;
                }
                boolean validated = capabilities.hasCapability(
                        NetworkCapabilities.NET_CAPABILITY_VALIDATED);
                if ((pass == 0) != validated) {
                    continue;
                }
                addDirectNetwork(result, network);
            }
        }
        return result;
    }

    private static boolean isDirectInternet(NetworkCapabilities capabilities) {
        return capabilities != null
                && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                && !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN);
    }

    private static void addDirectNetwork(ArrayList<Network> result, Network candidate) {
        if (!result.contains(candidate) && result.size() < MAX_DIRECT_NETWORKS) {
            result.add(candidate);
        }
    }

    private static InetAddress[] captureDnsServers(
            ConnectivityManager manager, Network network) throws Exception {
        LinkProperties properties = manager.getLinkProperties(network);
        if (properties == null) {
            return new InetAddress[0];
        }
        java.util.List<InetAddress> configured = properties.getDnsServers();
        if (configured == null || configured.isEmpty()
                || configured.size() > MAX_DNS_SERVERS) {
            return new InetAddress[0];
        }
        return sanitizeAddresses(configured.toArray(new InetAddress[configured.size()]),
                MAX_DNS_SERVERS, "DNS server count exceeds the safe bound.");
    }

    private static InetAddress[] sanitizeResolved(InetAddress[] resolved) throws Exception {
        return sanitizeAddresses(resolved, MAX_RESOLVED_ENDPOINTS,
                "SOCKS5 infrastructure resolution exceeds the safe bound.");
    }

    private static boolean containsAddress(InetAddress[] values, InetAddress target) {
        byte[] targetBytes = target == null ? null : target.getAddress();
        if (values == null || targetBytes == null) {
            return false;
        }
        for (InetAddress value : values) {
            if (value != null && Arrays.equals(value.getAddress(), targetBytes)) {
                return true;
            }
        }
        return false;
    }

    private static InetAddress[] sanitizeAddresses(
            InetAddress[] resolved, int maximum, String boundMessage) throws Exception {
        ArrayList<InetAddress> result = new ArrayList<InetAddress>();
        if (resolved == null) {
            return new InetAddress[0];
        }
        for (InetAddress candidate : resolved) {
            if (candidate == null) {
                continue;
            }
            byte[] bytes = candidate.getAddress();
            if (bytes == null || (bytes.length != 4 && bytes.length != 16)) {
                continue;
            }
            boolean duplicate = false;
            for (InetAddress accepted : result) {
                if (Arrays.equals(accepted.getAddress(), bytes)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                result.add(InetAddress.getByAddress(bytes));
                if (result.size() > maximum) {
                    throw new IllegalArgumentException(boundMessage);
                }
            }
        }
        return result.toArray(new InetAddress[result.size()]);
    }

    private static final class ResolvedInfrastructure {
        final InetAddress[] endpointAddresses;
        final InetAddress[] dnsServers;

        ResolvedInfrastructure(InetAddress[] endpointAddresses, InetAddress[] dnsServers) {
            this.endpointAddresses = endpointAddresses.clone();
            this.dnsServers = dnsServers.clone();
        }
    }

    private static String canonicalAddress(InetAddress address) {
        byte[] bytes = address == null ? null : address.getAddress();
        if (bytes == null || (bytes.length != 4 && bytes.length != 16)) {
            throw new IllegalArgumentException("SOCKS5 infrastructure address is invalid.");
        }
        return ProxyBypassPolicy.canonicalAddress(
                new ProxyBypassPolicy.AddressValue(bytes, bytes.length * 8));
    }

    private static String buildInMemoryYaml(ProxyConfig config, String numericEndpoint) {
        StringBuilder yaml = new StringBuilder(768);
        yaml.append("tunnel:\n");
        yaml.append("  mtu: ").append(MTU).append('\n');
        yaml.append("  ipv4: '").append(TUN_IPV4).append("'\n");
        yaml.append("  ipv6: '").append(TUN_IPV6).append("'\n");
        yaml.append("  icmp: 'off'\n");
        yaml.append("socks5:\n");
        yaml.append("  address: ");
        appendYamlQuoted(yaml, numericEndpoint);
        yaml.append('\n');
        yaml.append("  port: ").append(config.port()).append('\n');
        yaml.append("  udp: 'udp'\n");
        // Keep the UDP relay on the one reviewed mandatory-DIRECT infrastructure address.
        // A server-returned different BND.ADDR would otherwise re-enter this app-scoped TUN.
        yaml.append("  udp-address: ");
        appendYamlQuoted(yaml, numericEndpoint);
        yaml.append('\n');
        if (config.authEnabled()) {
            yaml.append("  username: ");
            appendYamlQuoted(yaml, config.username());
            yaml.append('\n');
            char[] password = config.passwordCopy();
            try {
                yaml.append("  password: ");
                appendYamlQuoted(yaml, password);
                yaml.append('\n');
            } finally {
                Arrays.fill(password, '\0');
            }
        }
        yaml.append("misc:\n");
        // The pinned engine treats the exact scalar "null" as its no-file sentinel.
        yaml.append("  log-file: null\n");
        yaml.append("  log-level: error\n");
        yaml.append("  connect-timeout: 10000\n");
        yaml.append("  tcp-read-write-timeout: 300000\n");
        yaml.append("  udp-read-write-timeout: 60000\n");
        return yaml.toString();
    }

    private static void appendYamlQuoted(StringBuilder output, String value) {
        output.append('\'');
        for (int index = 0; index < value.length(); index++) {
            char next = value.charAt(index);
            if (next == '\'') {
                output.append("''");
            } else {
                output.append(next);
            }
        }
        output.append('\'');
    }

    private static void appendYamlQuoted(StringBuilder output, char[] value) {
        output.append('\'');
        for (char next : value) {
            if (next == '\'') {
                output.append("''");
            } else {
                output.append(next);
            }
        }
        output.append('\'');
    }

    private void ensureForeground(String text) {
        NotificationManager manager =
                (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26 && manager != null) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, "Threads Mod proxy", NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("VPN routing and SOCKS5 engine liveness");
            channel.setShowBadge(false);
            manager.createNotificationChannel(channel);
        }
        startForeground(NOTIFICATION_ID, buildNotification(text));
    }

    private void setRuntimeState(String state, String notificationText) {
        runtimeState = state;
        NotificationManager manager =
                (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager != null) {
            try {
                manager.notify(NOTIFICATION_ID, buildNotification(notificationText));
            } catch (RuntimeException unavailable) {
                // Routing state remains authoritative; status-notification refresh is best effort.
            }
        }
    }

    private Notification buildNotification(String text) {
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        builder.setSmallIcon(android.R.drawable.stat_sys_warning);
        builder.setContentTitle("Threads Mod proxy");
        builder.setContentText(text);
        builder.setOngoing(true);
        builder.setCategory(Notification.CATEGORY_SERVICE);
        builder.setVisibility(Notification.VISIBILITY_PRIVATE);
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE);
        }

        Intent disconnect = new Intent(this, Socks5VpnService.class)
                .setAction(ACTION_DISCONNECT);
        int pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) {
            pendingFlags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent pendingDisconnect = PendingIntent.getService(
                this, DISCONNECT_REQUEST_CODE, disconnect, pendingFlags);
        builder.addAction(new Notification.Action.Builder(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Disconnect",
                pendingDisconnect).build());
        return builder.build();
    }

    private boolean isCurrent(int generation) {
        return requestGeneration.get() == generation;
    }

    private static void startAction(Context context, String action) {
        if (context == null) {
            throw new IllegalArgumentException("Proxy service context is missing.");
        }
        Context application = context.getApplicationContext();
        Context owner = application == null ? context : application;
        Intent intent = new Intent(owner, Socks5VpnService.class).setAction(action);
        if (Build.VERSION.SDK_INT >= 26) {
            owner.startForegroundService(intent);
        } else {
            owner.startService(intent);
        }
    }

    private static void closeQuietly(ParcelFileDescriptor descriptor) {
        if (descriptor == null) {
            return;
        }
        try {
            descriptor.close();
        } catch (IOException ignored) {
            // Descriptors are process-owned and never rendered into diagnostics.
        }
    }
}
