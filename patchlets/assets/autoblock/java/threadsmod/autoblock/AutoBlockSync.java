package threadsmod.autoblock;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.util.Log;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import net.i2p.crypto.eddsa.EdDSAEngine;
import net.i2p.crypto.eddsa.EdDSAPublicKey;
import net.i2p.crypto.eddsa.spec.EdDSANamedCurveTable;
import net.i2p.crypto.eddsa.spec.EdDSAPublicKeySpec;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.lang.ref.WeakReference;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.CookieHandler;
import java.net.SocketException;
import java.net.URL;
import java.net.UnknownHostException;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLException;

/**
 * Always-on, foreground-only port of Clone Blocker's server-list workflow.
 *
 * The list connection is isolated from Threads' networking stack and never
 * receives a UserSession, cookie, token, device identifier, or viewer id. The
 * actual account mutation is delegated to ThreadsBlockBridge, which calls the
 * app's existing authenticated block helper.
 */
public final class AutoBlockSync {
    private static final String TAG = "ThreadsModAutoBlock";
    private static final String PREFS = "threadsmod_autoblock";
    // CloneBlocker's raw 32-byte Ed25519 public key.
    private static final String LIST_KEY_RAW =
            "fYcRAV8CRof15IAinUoDOZuBbqqDtDXDPl3lwSLoMhk";

    private static final int MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
    // Chunked v3 caps shared with ObjectFetcher and ChunkInstaller. MAX_BUCKET_BITS bounds the
    // install plan at 65,536 buckets, which stays far above MAX_INDEX_ROWS at any chunk size.
    static final int MAX_ROOT_BYTES = 512 * 1024;
    static final int MAX_GROUP_BYTES = 64 * 1024;
    static final int MAX_CHUNK_GZ_BYTES = 256 * 1024;
    static final int MAX_CHUNK_INFLATED_BYTES = 4 * 1024 * 1024;
    static final int MAX_CHUNK_ROWS = 8192;
    static final int MAX_INDEX_ROWS = 2000000;
    static final int MAX_BUCKET_BITS = 16;
    static final int MAX_GROUP_BITS = 8;
    private static final int MAX_PENDING_FORCE_VIEWERS = 8;
    private static final int MAX_RESOLVED_AUTHOR_MODELS = 64;
    private static final int MAX_LOCAL_COMPLETION_REVIEW_VIEWERS = 8;
    private static final int MAX_VISIBLE_CONTROL_REGISTRATIONS = 256;
    private static final int MAX_PASSIVE_LOOKUP_QUEUE = 256;
    private static final int MAX_PASSIVE_MATCHES = 128;
    private static final long FETCH_INTERVAL_MS = 10L * 60L * 1000L;
    private static final long MAX_LIST_REFRESH_DEADLINE_FUTURE_MS =
            FETCH_INTERVAL_MS + 2L * 60L * 1000L;
    private static final long CACHE_MAX_AGE_MS = 7L * 24L * 60L * 60L * 1000L;
    private static final long SIGNED_LIST_MAX_AGE_MS = 30L * 24L * 60L * 60L * 1000L;
    private static final long FAILURE_BACKOFF_MS = 2L * 60L * 1000L;
    // Bounded foreground retry ladder installed after a FAILED list attempt; a successful
    // attempt re-installs FETCH_INTERVAL_MS. Every step is below
    // MAX_LIST_REFRESH_DEADLINE_FUTURE_MS, so a ladder deadline passes readDeadline's bound.
    private static final long[] LIST_REFRESH_FAILURE_LADDER_MS = listRefreshFailureLadderMs();
    private static final int MAX_LIST_REFRESH_FAILURE_RETRIES =
            LIST_REFRESH_FAILURE_LADDER_MS.length;

    /**
     * Built element by element on purpose: an array literal compiles to a
     * fill-array-data payload in the static initializer, which the raw-DEX bridge
     * proof does not model. Five explicit stores prove the same fixed ladder.
     */
    private static long[] listRefreshFailureLadderMs() {
        long[] ladder = new long[5];
        ladder[0] = 15L * 1000L;
        ladder[1] = 30L * 1000L;
        ladder[2] = 60L * 1000L;
        ladder[3] = 120L * 1000L;
        ladder[4] = 300L * 1000L;
        return ladder;
    }
    private static final long PASSIVE_RESELECT_DELAY_MS = 250L;
    private static final long HISTORY_RETENTION_MS = 24L * 60L * 60L * 1000L;
    private static final long WATCHDOG_MS = 45L * 1000L;
    private static final long SAFETY_REVIEW_WAKE_MS = 5L * 60L * 1000L;
    private static final long RESOLVED_AUTHOR_MODEL_TTL_MS = 10L * 60L * 1000L;
    private static final int MAX_HISTORY_EVENTS = 2000;
    private static final int MAX_HISTORY_BYTES = 32 * 1024;

    private static final String KEY_ENABLED = "enabled";
    private static final String KEY_STATUS = "status";
    private static final String KEY_ETAG = "list_etag";
    private static final String KEY_ETAG_URL = "list_etag_url";
    private static final String KEY_LIST_REFRESH_NOT_BEFORE = "list_refresh_not_before";
    // Retired SharedPreferences list storage is deletion-only after the SQLite migration.
    private static final String LEGACY_KEY_FETCHED_AT = "list_fetched_at";
    private static final String LEGACY_KEY_UPDATED_AT = "list_updated_at";
    private static final String LEGACY_KEY_CACHE_VALID = "list_cache_valid";
    private static final String LEGACY_KEY_TARGET_CACHE = "list_threads_targets";

    static final String LIST_PHASE_WAITING = "waiting";
    static final String LIST_PHASE_FETCHING = "fetching";
    static final String LIST_PHASE_VERIFYING = "verifying";
    static final String LIST_PHASE_INDEXING = "indexing";
    static final String LIST_PHASE_READY = "ready";
    static final String LIST_PHASE_UNCHANGED = "unchanged";
    static final String LIST_PHASE_RETAINED_ERROR = "retained_error";
    static final String LIST_PHASE_INVALID = "invalid";

    // Closed per-mirror list fetch failure classes: the only fetch-failure text that may
    // reach status or diagnostics. Chosen by exception type or a typed field, never from an
    // exception message, URL, header, or body.
    static final String FAILURE_TOO_LARGE = "too_large";
    static final String FAILURE_HTTP_PREFIX = "http_";
    static final String FAILURE_TIMEOUT = "timeout";
    static final String FAILURE_UNREACHABLE = "unreachable";
    static final String FAILURE_TLS = "tls";
    static final String FAILURE_IO = "io";
    static final String FAILURE_SIGNATURE = "signature";
    static final String FAILURE_SCHEMA = "schema";
    static final String FAILURE_CLOCK = "clock";
    static final String FAILURE_STALE = "stale";
    static final String FAILURE_ROLLBACK = "rollback";
    static final String FAILURE_TARGET_CAP = "target_cap";
    static final String FAILURE_COOKIE_REFUSED = "cookie_refused";
    static final String FAILURE_INTERNAL = "internal";

    private static final AtomicBoolean RUNNING = new AtomicBoolean(false);
    private static final AtomicBoolean LIST_REFRESH_RUNNING = new AtomicBoolean(false);
    private static final AtomicBoolean PASSIVE_LOOKUP_RUNNING = new AtomicBoolean(false);
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final Random RANDOM = new Random();
    private static final Object MANUAL_CALLBACK_LOCK = new Object();
    private static final Object FORCE_REFRESH_LOCK = new Object();
    private static final Object SCHEDULER_LOCK = new Object();
    private static final Object LOCAL_BACKOFF_LOCK = new Object();
    private static final Object RESOLVED_AUTHOR_MODEL_LOCK = new Object();
    private static final Object COMPLETION_REVIEW_LOCK = new Object();
    private static final Object PASSIVE_VISIBILITY_LOCK = new Object();
    private static final Object PASSIVE_ADMISSION_LOCK = new Object();
    private static final Object LIST_REFRESH_DEADLINE_LOCK = new Object();
    private static final Object LIST_REFRESH_LADDER_LOCK = new Object();
    private static final Object PASSIVE_STORE_PAUSE_LOCK = new Object();
    private static final Object INLINE_RENDER_DIAGNOSTIC_LOCK = new Object();
    private static final Map<String, ArrayList<ManualBlockCallback>> MANUAL_CALLBACKS =
            new HashMap<String, ArrayList<ManualBlockCallback>>();
    private static final LinkedHashMap<String, ResolvedAuthorModel> RESOLVED_AUTHOR_MODELS =
            new LinkedHashMap<String, ResolvedAuthorModel>(16, 0.75f, true);
    private static final IdentityHashMap<Object, PassiveRegistration> PASSIVE_REGISTRATIONS =
            new IdentityHashMap<Object, PassiveRegistration>();
    private static final ArrayDeque<String> PASSIVE_LOOKUP_QUEUE = new ArrayDeque<String>();
    private static final HashSet<String> PASSIVE_LOOKUP_QUEUED = new HashSet<String>();
    private static final LinkedHashMap<String, Long> PASSIVE_MATCH_GENERATIONS =
            new LinkedHashMap<String, Long>(16, 0.75f, true);

    private static volatile WeakReference<Activity> currentActivity =
            new WeakReference<Activity>(null);
    private static volatile Object currentSession;
    private static volatile String currentViewer;
    private static volatile boolean foreground;
    static volatile String listRefreshPhase = LIST_PHASE_WAITING;
    private static int inlineHookSeenCount;
    private static int inlineButtonRenderedCount;
    private static int inlineRequestUnavailableCount;
    private static int inlineAdapterExceptionCount;
    private static final LinkedHashSet<String> FORCE_REFRESH_VIEWERS =
            new LinkedHashSet<String>();
    private static final LinkedHashSet<String> LIST_FORCE_REFRESH_VIEWERS =
            new LinkedHashSet<String>();
    private static long schedulerSequence;
    private static long schedulerOwnerToken;
    private static String schedulerOwnerViewer = "";
    private static WeakReference<Activity> schedulerOwnerActivity =
            new WeakReference<Activity>(null);
    private static boolean schedulerMutationInFlight;
    private static boolean schedulerOwnerForceRefresh;
    private static final Map<String, Long> LOCAL_FAILURE_BACKOFFS =
            new HashMap<String, Long>();
    private static final LinkedHashSet<String> LOCAL_COMPLETION_REVIEW_TARGETS =
            new LinkedHashSet<String>();
    private static final HashSet<String> LOCAL_COMPLETION_REVIEW_PAUSED_VIEWERS =
            new HashSet<String>();
    private static boolean localCompletionReviewOverflow;
    private static long localListRefreshNotBefore;
    // Failed list attempts in the current foreground session; guarded by LIST_REFRESH_LADDER_LOCK.
    private static int listRefreshFailureStreak;
    // Bounded "mirror 1 too_large, ..." text built from closed tokens only. Written by the
    // refresh worker before it flips listRefreshPhase; cleared on the main thread before start.
    private static volatile String listRefreshFailureSummary = "";
    // Main-thread only: one missing-index deadline bypass per foreground session, bounded by
    // the start time of the last admitted attempt.
    private static boolean listRefreshResumeStartPending;
    private static long listRefreshLastStartMs;
    private static boolean passiveStorePaused;
    private static long passiveStorePauseGeneration;

    private static final Runnable LIST_REFRESH_WAKE = new Runnable() {
        @Override
        public void run() {
            Activity activity = getForegroundActivity();
            String viewer = getCurrentViewer();
            if (activity == null || viewer == null || !isEnabled(activity)) {
                return;
            }
            requestListRefresh(activity, viewer, false);
        }
    };

    static {
        ModStateStore.setManualQueueListener(new ModStateStore.ManualQueueListener() {
            @Override
            public void onManualQueueChanged(Activity ignored, String ignoredViewer) {
                scheduleManualDrain(0L);
            }
        });
    }

    private AutoBlockSync() {}

    public static void onResume(Activity activity, Object userSession) {
        if (activity == null) {
            return;
        }
        if (!isMainLooperThread()) {
            setStatus(activity, null,
                    "Foreground lifecycle arrived off the main thread; account actions remain paused.");
            return;
        }
        String viewer = userSession == null ? null : viewerId(userSession);
        if (userSession == null || !isDecimalId(viewer) || viewer.length() > 24) {
            String previousViewer = currentViewer;
            MAIN.removeCallbacks(LIST_REFRESH_WAKE);
            currentActivity = new WeakReference<Activity>(activity);
            currentSession = null;
            currentViewer = null;
            foreground = false;
            clearResolvedAuthorModels();
            clearPassiveVisibility();
            ModStateStore.clearActiveViewer(activity);
            releasePassiveSchedulerForContextChange(activity, null);
            if (isDecimalId(previousViewer)) {
                ModStateStore.recordRuntimeState(
                        activity,
                        previousViewer,
                        "signed_out",
                        "No valid signed-in Threads viewer is available; account actions are paused.",
                        false);
            }
            return;
        }
        Activity previousActivity = currentActivity.get();
        String previousViewer = currentViewer;
        if (!ModStateStore.setValidatedActiveViewer(activity, viewer)) {
            MAIN.removeCallbacks(LIST_REFRESH_WAKE);
            currentActivity = new WeakReference<Activity>(activity);
            currentSession = null;
            currentViewer = null;
            foreground = false;
            clearResolvedAuthorModels();
            clearPassiveVisibility();
            releasePassiveSchedulerForContextChange(activity, null);
            ModStateStore.recordRuntimeState(
                    activity,
                    null,
                    "viewer_scope_unavailable",
                    "The retired viewer preference could not be cleared; account actions remain paused.",
                    true);
            return;
        }
        boolean contextChanged = previousActivity != activity
                || viewer == null
                || !viewer.equals(previousViewer);
        boolean resumedFromBackground = !foreground;
        boolean newForegroundRun = !foreground || contextChanged;
        currentActivity = new WeakReference<Activity>(activity);
        currentSession = userSession;
        currentViewer = viewer;
        foreground = true;
        if (resumedFromBackground) {
            // A new foreground session: the bounded failure ladder restarts, and while no
            // verified index exists the first ordinary request may start ahead of a pending
            // deadline. Both are consumed by requestListRefresh below.
            resetListRefreshFailureLadder();
            listRefreshResumeStartPending = true;
        }
        scopeResolvedAuthorModels(viewer, userSession);
        if (newForegroundRun) {
            if (contextChanged) {
                clearPassiveVisibility();
            } else {
                pausePassiveVisibility();
            }
            releasePassiveSchedulerForContextChange(activity, viewer);
        }
        int passiveRecovered = RUNNING.get()
                ? 0 : ModStateStore.recoverInterruptedPassive(activity, viewer);
        int recovered = RUNNING.get()
                ? 0 : ModStateStore.recoverInterruptedManual(activity, viewer);
        if (passiveRecovered < 0) {
            setStatus(activity, viewer,
                    "Interrupted passive state needs review; automatic blocking is paused.");
            ModStateStore.recordRuntimeState(
                    activity, viewer, "passive_recovery_invalid",
                    "Interrupted passive state could not be quarantined safely.", true);
        } else if (passiveRecovered > 0) {
            setStatus(activity, viewer,
                    "An interrupted passive block was quarantined for review.");
            ModStateStore.recordRuntimeState(
                    activity, viewer, "passive_recovered",
                    "Interrupted passive work was marked abandoned for review.", false);
        } else if (recovered > 0) {
            setStatus(activity, viewer, recovered
                    + " interrupted inline block(s) need review in Activity before retry.");
            ModStateStore.recordRuntimeState(
                    activity, viewer, "manual_recovered",
                    "Interrupted inline work was marked abandoned for review.", false);
        } else {
            ModStateStore.recordRuntimeState(
                    activity, viewer, "foreground", "Threads is in the foreground.", false);
        }
        if (isEnabled(activity)) {
            requestListRefresh(activity, viewer, false);
        }
        if (ModStateStore.nextQueued(activity, viewer) != null) {
            scheduleManualDrain(0L);
        } else if (isEnabled(activity)) {
            start(activity, userSession, viewer, false);
        }
    }

    public static void onPause(Activity activity) {
        if (!isMainLooperThread()) {
            synchronized (PASSIVE_ADMISSION_LOCK) {
                foreground = false;
                pausePassiveVisibility();
            }
            return;
        }
        Activity current = currentActivity.get();
        if (current == null || current == activity) {
            MAIN.removeCallbacks(LIST_REFRESH_WAKE);
            foreground = false;
            pausePassiveVisibility();
            ModStateStore.recordRuntimeState(
                    activity, currentViewer, "background", "Threads left the foreground.", false);
        }
    }

    /**
     * Always on. Passive blocking has no user-facing switch, so there is nothing to opt
     * into and nothing to read back; the only false answer left is the one a null context
     * must still fail closed on. The Settings screen discloses the behaviour instead.
     */
    public static boolean isEnabled(Context context) {
        return context != null;
    }

    public static boolean isRunning() {
        return RUNNING.get();
    }

    public static boolean isRefreshingList() {
        return LIST_REFRESH_RUNNING.get();
    }

    /** Bounded, identifier-free refresh and index status for the mod Activity surfaces. */
    public static String getListStatus(Context context) {
        if (context == null) {
            return "List fetch: Unavailable\nRecords: Unavailable\n"
                    + "New this refresh: Unavailable\nDatabase index: Unavailable"
                    + "\nInline control: " + getInlineRenderStatus();
        }
        try {
            BlocklistStore.Snapshot snapshot = BlocklistStore.snapshot(context);
            String phase = listRefreshPhase;
            String fetch;
            if (LIST_PHASE_FETCHING.equals(phase)) {
                fetch = "Fetching…";
            } else if (LIST_PHASE_VERIFYING.equals(phase)) {
                fetch = "Verifying…";
            } else if (LIST_PHASE_INDEXING.equals(phase)) {
                fetch = "Indexing…";
            } else if (LIST_PHASE_UNCHANGED.equals(phase)) {
                fetch = "Complete — signed list unchanged";
            } else if (LIST_PHASE_RETAINED_ERROR.equals(phase)) {
                // Closed per-mirror classes only, e.g. "(mirror 1 too_large, mirror 2 timeout,
                // mirror 3 http_503)"; never a URL, header, body, or exception text.
                String failures = listRefreshFailureSummary;
                fetch = (snapshot.valid
                        ? "Failed — previous index retained" : "Failed — no valid index")
                        + (failures.length() > 0 ? " (" + failures + ")" : "");
            } else if (LIST_PHASE_INVALID.equals(phase)) {
                fetch = "Paused — local refresh state needs review";
            } else if (LIST_PHASE_READY.equals(phase) || snapshot.valid) {
                fetch = "Complete";
            } else if (LIST_REFRESH_RUNNING.get()) {
                fetch = "Starting…";
            } else {
                fetch = "Waiting for first verified refresh";
            }

            String records = snapshot.valid
                    ? String.valueOf(snapshot.targetCount) : "Unavailable";
            String added = snapshot.valid && snapshot.newTargetCount >= 0
                    ? String.valueOf(snapshot.newTargetCount) : "Unavailable";
            String database;
            if (snapshot.valid) {
                database = LIST_PHASE_INDEXING.equals(phase)
                        ? "Indexing… · generation " + snapshot.generation + " remains active"
                        : "Ready · generation " + snapshot.generation;
            } else if (BlocklistStore.STATE_MISSING.equals(snapshot.state)) {
                database = "Missing";
            } else {
                database = "Needs review";
            }
            return "List fetch: " + fetch
                    + "\nRecords: " + records
                    + "\nNew this refresh: " + added
                    + "\nDatabase index: " + database
                    + "\nInline control: " + getInlineRenderStatus();
        } catch (Throwable ignored) {
            return "List fetch: Unavailable\nRecords: Unavailable\n"
                    + "New this refresh: Unavailable\nDatabase index: Needs review"
                    + "\nInline control: " + getInlineRenderStatus();
        }
    }

    /** Receives only fixed identifier-free stages from the exact-SHA inline adapter. */
    public static void recordInlineRenderStage(String stage) {
        synchronized (INLINE_RENDER_DIAGNOSTIC_LOCK) {
            if ("hook_seen".equals(stage)) {
                inlineHookSeenCount = saturatingIncrement(inlineHookSeenCount);
            } else if ("button_rendered".equals(stage)) {
                inlineButtonRenderedCount = saturatingIncrement(inlineButtonRenderedCount);
            } else if ("report_request_unavailable".equals(stage)) {
                inlineRequestUnavailableCount = saturatingIncrement(
                        inlineRequestUnavailableCount);
            } else if ("adapter_exception".equals(stage)) {
                inlineAdapterExceptionCount = saturatingIncrement(inlineAdapterExceptionCount);
            }
        }
    }

    private static String getInlineRenderStatus() {
        synchronized (INLINE_RENDER_DIAGNOSTIC_LOCK) {
            if (inlineHookSeenCount == 0 && inlineButtonRenderedCount == 0
                    && inlineRequestUnavailableCount == 0
                    && inlineAdapterExceptionCount == 0) {
                return "not observed in this process";
            }
            return "hook=" + inlineHookSeenCount
                    + ", rendered=" + inlineButtonRenderedCount
                    + ", request-unavailable=" + inlineRequestUnavailableCount
                    + ", adapter-errors=" + inlineAdapterExceptionCount
                    + " (this process; no account data logged)";
        }
    }

    private static int saturatingIncrement(int value) {
        return value == Integer.MAX_VALUE ? value : value + 1;
    }

    public static String getStatus(Context context) {
        return getStatus(context, getCurrentViewer());
    }

    static String getStatus(Context context, String viewer) {
        if (context == null) {
            return "Local status is unavailable; account actions remain fail-closed.";
        }
        try {
            SharedPreferences preferences = prefs(context);
            // Passive blocking is always on, so the only honest fallback before the first
            // status write is that it is waiting for a session. Reading KEY_ENABLED here would
            // report "disabled" on a fresh install, contradicting what the runtime is doing.
            String fallback = "Enabled; waiting for a signed-in foreground session.";
            return preferences.getString(statusKey(viewer), fallback);
        } catch (ClassCastException invalidLocalState) {
            return "Local status state needs review; account actions remain fail-closed.";
        }
    }

    /** Current validated scheduler configuration for Settings and inline disclosure. */
    public static BlockLimits getLimits(Context context) {
        return BlockLimitsStore.load(context);
    }

    /** Applies the newly saved passive delay range to the next passive decision. */
    public static void onLimitsChanged(Context context) {
        if (context == null) {
            return;
        }
        setStatus(context, getCurrentViewer(),
                "Passive delay updated; queued work and attempt history were preserved.");
        scheduleManualDrain(0L);
    }

    /** Current host activity, available only while the real Threads UI is foreground. */
    public static Activity getForegroundActivity() {
        Activity activity = currentActivity.get();
        if (!foreground || activity == null || activity.isFinishing() || activity.isDestroyed()) {
            return null;
        }
        return activity;
    }

    /** Viewer-scoped identity used only for local self-block and persistence checks. */
    public static String getCurrentViewer() {
        String viewer = currentViewer;
        return isDecimalId(viewer) && viewer.length() <= 24 ? viewer : null;
    }

    /**
     * Registers one exact-row, immutable visibility token. This method is deliberately
     * memory-only: Compose callbacks never touch SQLite or the native block bridge.
     */
    public static boolean registerVisibleControl(
            Object token, String rowKey, String targetId, String username) {
        if (!isMainLooperThread()
                || token == null || rowKey == null || rowKey.length() == 0 || rowKey.length() > 160
                || !isDecimalId(targetId) || targetId.length() > 24) {
            return false;
        }
        String viewer = getCurrentViewer();
        if (viewer == null || viewer.equals(targetId)) {
            return false;
        }
        String safeUsername = BlocklistStore.normalizedUsername(username);
        if (safeUsername.length() == 0) {
            return false;
        }
        synchronized (PASSIVE_VISIBILITY_LOCK) {
            PassiveRegistration existing = PASSIVE_REGISTRATIONS.get(token);
            if (existing != null) {
                if (!existing.viewer.equals(viewer)
                        || !existing.targetId.equals(targetId)
                        || !existing.rowKey.equals(rowKey)) {
                    removePassiveRegistrationLocked(token, existing);
                } else {
                    return true;
                }
            }
            if (PASSIVE_REGISTRATIONS.size() >= MAX_VISIBLE_CONTROL_REGISTRATIONS) {
                return false;
            }
            PASSIVE_REGISTRATIONS.put(
                    token, new PassiveRegistration(viewer, rowKey, targetId, safeUsername));
            return true;
        }
    }

    /** Records only visibility transitions and schedules a bounded background indexed lookup. */
    public static void updateVisibleControl(Object token, boolean visible) {
        if (token == null) {
            return;
        }
        if (!isMainLooperThread()) {
            synchronized (PASSIVE_ADMISSION_LOCK) {
                synchronized (PASSIVE_VISIBILITY_LOCK) {
                    PassiveRegistration registration = PASSIVE_REGISTRATIONS.remove(token);
                    if (registration != null) {
                        removePassiveRegistrationLocked(token, registration);
                    }
                }
            }
            return;
        }
        String lookupKey = null;
        Context context = null;
        synchronized (PASSIVE_VISIBILITY_LOCK) {
            PassiveRegistration registration = PASSIVE_REGISTRATIONS.get(token);
            String viewer = getCurrentViewer();
            if (registration == null || viewer == null
                    || !registration.viewer.equals(viewer)) {
                return;
            }
            if (registration.visible == visible) {
                return;
            }
            registration.visible = visible;
            lookupKey = passiveKey(registration.viewer, registration.targetId);
            if (!visible) {
                if (!hasVisibleRegistrationLocked(
                        registration.viewer, registration.targetId)) {
                    PASSIVE_MATCH_GENERATIONS.remove(lookupKey);
                    removeQueuedPassiveLookupLocked(lookupKey);
                }
                return;
            }
            if (isPassiveStorePaused()) {
                return;
            }
            Activity activity = getForegroundActivity();
            if (activity == null || !isEnabled(activity)) {
                return;
            }
            context = activity.getApplicationContext();
            enqueuePassiveLookupLocked(lookupKey);
        }
        startPassiveLookupWorker(context);
    }

    /** Releases a remembered row token; the last hidden copy removes its pending match. */
    public static void unregisterVisibleControl(Object token) {
        if (token == null) {
            return;
        }
        if (!isMainLooperThread()) {
            synchronized (PASSIVE_ADMISSION_LOCK) {
                forgetVisibleControl(token);
            }
            return;
        }
        forgetVisibleControl(token);
    }

    private static void forgetVisibleControl(Object token) {
        synchronized (PASSIVE_VISIBILITY_LOCK) {
            PassiveRegistration registration = PASSIVE_REGISTRATIONS.remove(token);
            if (registration != null) {
                removePassiveRegistrationLocked(token, registration);
            }
        }
    }

    /**
     * Records one terminal inline failure that happened before durable queue
     * ownership. The caller supplies only a closed stage token and whether the
     * row carried an opaque model; operation identities never cross this API.
     */
    public static void recordInlinePreEnqueueFailure(
            String stage, boolean resolvedRowModel) {
        Activity activity = currentActivity.get();
        String viewer = getCurrentViewer();
        boolean scoped = activity != null && !activity.isDestroyed()
                && isDecimalId(viewer) && viewer.length() <= 24;
        boolean backoffPersisted = false;
        if (scoped) {
            try {
                backoffPersisted = persistRetryDeadline(activity, viewer);
            } catch (Throwable ignored) {
                // The closed diagnostic reports failed retry-state persistence.
            }
        }

        BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                stage, false, resolvedRowModel, false, backoffPersisted);
        if (activity != null && !activity.isDestroyed()) {
            try {
                ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
            } catch (Throwable ignored) {
                // Diagnostic persistence is optional to the fail-closed UI reset.
            }
            try {
                setStatus(activity, viewer, diagnostic.status());
            } catch (Throwable ignored) {
                // The bounded log remains available when local status cannot save.
            }
        }
        try {
            Log.w(TAG, diagnostic.logLine());
        } catch (Throwable ignored) {
            // Logging must never prevent the terminal UI callback.
        }
        if (scoped) {
            scheduleManualDrain(FAILURE_BACKOFF_MS + 1000L);
        }
    }

    /**
     * Queue a user-initiated inline action through the same single-flight scheduler as Auto Block.
     * The target is persisted before a native mutation can start; success is reported only by the
     * native bridge callback.
     */
    public static boolean enqueueManual(
            String targetId,
            String label,
            ManualBlockCallback callback) {
        return enqueueManual(targetId, label, null, callback);
    }

    public static boolean enqueueManual(
            String targetId,
            String label,
            Object resolvedAuthorModel,
            ManualBlockCallback callback) {
        if (!isMainLooperThread()) {
            if (callback != null) {
                callback.onManualBlockFailure(targetId, "queue_rejected");
            }
            return false;
        }
        final Activity activity = getForegroundActivity();
        final String viewer = getCurrentViewer();
        final Object session = currentSession;
        if (activity == null || session == null || viewer == null
                || !isDecimalId(targetId) || targetId.length() > 24
                || viewer.equals(targetId)) {
            if (callback != null) {
                callback.onManualBlockFailure(targetId, "invalid_or_self_target");
            }
            return false;
        }
        if (!viewer.equals(viewerId(session))) {
            if (callback != null) {
                callback.onManualBlockFailure(targetId, "viewer_changed");
            }
            return false;
        }
        if (ModStateStore.isCompletedTarget(activity, viewer, targetId)) {
            // A locally completed target is a closed validation refusal, not a scheduler fault.
            if (callback != null) {
                callback.onManualBlockFailure(targetId, "already_completed");
            }
            return false;
        }

        String callbackKey = manualCallbackKey(viewer, targetId);
        addManualCallback(callbackKey, callback);
        if (!ModStateStore.enqueueManual(
                activity, viewer, targetId, label, ModStateStore.SOURCE_INLINE)) {
            removeManualCallback(callbackKey, callback);
            if (callback != null) {
                callback.onManualBlockFailure(targetId, "queue_rejected");
            }
            return false;
        }
        rememberResolvedAuthorModel(
                viewer, targetId, session, resolvedAuthorModel);
        if (callback != null) {
            callback.onManualBlockQueued(targetId);
        }
        setStatus(activity, viewer, "Inline Block queued for Threads user " + targetId + ".");
        scheduleManualDrain(0L);
        return true;
    }

    public static void enableAndSync(Activity activity) {
        if (activity == null) {
            return;
        }
        prefs(activity).edit().putBoolean(KEY_ENABLED, true).apply();
        Object session = currentSession;
        String viewer = currentViewer;
        requestForceRefresh(viewer);
        if (session == null || viewer == null || viewer.length() == 0) {
            setStatus(activity, viewer, "Sign in to Threads, then reopen the app.");
            showToast(activity, "Waiting for a Threads session.");
            return;
        }
        Activity host = getForegroundActivity();
        if (host == null) {
            setStatus(activity, viewer,
                    "Sync requested; return to the Threads feed to continue safely.");
            showToast(activity, "Sync queued. Return to the Threads feed to continue.");
            return;
        }
        showToast(activity, "Indexed-list refresh started.");
        start(host, session, viewer, true);
    }

    private static void start(
            Activity activity,
            Object userSession,
            String viewer,
            boolean forceRefresh) {
        if (!isMainLooperThread()) {
            scheduleManualDrain(0L);
            return;
        }
        if (activity == null || userSession == null || !isEnabled(activity)) {
            return;
        }
        if (!isDecimalId(viewer) || viewer.length() > 24) {
            setStatus(activity, viewer, "Waiting for a valid signed-in Threads account.");
            return;
        }
        requestListRefresh(activity, viewer, forceRefresh);
        if (forceRefresh) {
            if (!requestForceRefresh(viewer)) {
                setStatus(activity, viewer,
                        "The indexed-list refresh was requested, but the bounded block-check "
                                + "queue is full; existing viewer requests were preserved.");
                return;
            }
        }
        if (!ModStateStore.isPassiveRunningClear(activity, viewer)) {
            setStatus(activity, viewer,
                    "Interrupted passive state needs review; automatic blocking remains paused.");
            return;
        }
        if (!BlockLimitsStore.isValid(activity)) {
            setStatus(activity, viewer,
                    "Stored passive delay needs review; passive blocking remains fail-closed "
                            + "until both delay values are saved again.");
            scheduleManualDrain(SAFETY_REVIEW_WAKE_MS);
            return;
        }

        SharedPreferences p = prefs(activity);
        if (ModStateStore.nextQueued(activity, viewer) != null) {
            setStatus(activity, viewer, "A user-requested inline Block is queued first.");
            scheduleManualDrain(0L);
            return;
        }
        if (isPassiveStorePaused()) {
            setStatus(activity, viewer,
                    "Indexed-list storage needs a verified replacement; passive blocking is paused.");
            return;
        }
        long now = System.currentTimeMillis();
        DeadlineState retry = readRetryDeadline(p, viewer, now);
        if (!retry.valid) {
            setStatus(activity, viewer,
                    "Local failure-pause state needs review; blocking remains fail-closed.");
            scheduleManualDrain(SAFETY_REVIEW_WAKE_MS);
            return;
        }
        long retryAt = retry.value;
        if (retryAt > now) {
            setStatus(activity, viewer, "Paused after a failure; retry available later.");
            scheduleManualDrain(retryAt - now + 1000L);
            return;
        }
        long paceWait = millisUntilPassivePaceAllowed(activity, viewer);
        if (paceWait > 0L) {
            setStatus(activity, viewer, paceWait == SAFETY_REVIEW_WAKE_MS
                    ? "Local pacing state needs review; blocking remains fail-closed."
                    : "Waiting for the configured delay before passive blocking.");
            scheduleManualDrain(paceWait);
            return;
        }
        boolean useForceRefresh = consumeForceRefresh(viewer);
        long schedulerToken = tryAcquireScheduler(activity, viewer, useForceRefresh);
        if (schedulerToken == 0L) {
            if (useForceRefresh) {
                requestForceRefresh(viewer);
            }
            setStatus(activity, viewer, "A block action is already running.");
            return;
        }

        setStatus(activity, viewer, "Checking indexed matches for profiles visible on screen...");
        try {
            Thread worker = new Thread(
                    new FetchWorker(
                            activity, userSession, viewer, useForceRefresh, schedulerToken),
                    "ThreadsModAutoBlockFetch");
            worker.start();
        } catch (Throwable ignored) {
            if (useForceRefresh) {
                requestForceRefresh(viewer);
            }
            try {
                persistRetryDeadline(activity, viewer);
                setStatus(activity, viewer,
                        "Passive matching worker could not start; retry remains safely paused.");
                ModStateStore.recordRuntimeState(
                        activity, viewer, "passive_worker_start_rejected",
                        "Passive matching is paused until a later foreground wake.", true);
            } catch (Throwable stateFailure) {
                // The in-memory failure deadline was installed before its durable commit.
            } finally {
                releaseSchedulerAndContinue(
                        schedulerToken, activity, viewer,
                        FAILURE_BACKOFF_MS + 1000L, true);
            }
        }
    }

    private static final class FetchWorker implements Runnable {
        private final WeakReference<Activity> activityRef;
        private final Object userSession;
        private final String viewer;
        private final boolean forceRefresh;
        private final long schedulerToken;

        FetchWorker(
                Activity activity,
                Object userSession,
                String viewer,
                boolean forceRefresh,
                long schedulerToken) {
            this.activityRef = new WeakReference<Activity>(activity);
            this.userSession = userSession;
            this.viewer = viewer;
            this.forceRefresh = forceRefresh;
            this.schedulerToken = schedulerToken;
        }

        @Override
        public void run() {
            try {
                final Activity activity = activityRef.get();
                if (activity == null) {
                    if (forceRefresh) {
                        requestForceRefresh(viewer);
                    }
                    releaseSchedulerAndContinue(
                            schedulerToken, null, viewer, 0L, true);
                    return;
                }
                final PassiveTargetSelection selection =
                        loadTarget(activity, viewer, forceRefresh);
                boolean posted = MAIN.post(new Runnable() {
                    @Override
                    public void run() {
                        if (!isSchedulerOwner(schedulerToken)) {
                            return;
                        }
                        if (selection.storeBlocked) {
                            setStatus(activity, viewer,
                                    "Indexed-list storage needs a verified replacement; passive blocking is paused.");
                            releaseSchedulerAndContinue(
                                    schedulerToken, activity, viewer, 0L, false);
                            return;
                        }
                        if (selection.completionReviewBlocked) {
                            setStatus(activity, viewer,
                                    "Completed-target or completion-review state needs attention; "
                                            + "automatic work remains paused.");
                            releaseSchedulerAndContinue(
                                    schedulerToken, activity, viewer, 0L, false);
                            return;
                        }
                        if (selection.retrySelection) {
                            setStatus(activity, viewer,
                                    "A stale visible match was discarded; a fresh drain will "
                                            + "independently select again.");
                            releaseSchedulerAndContinue(
                                    schedulerToken, activity, viewer,
                                    PASSIVE_RESELECT_DELAY_MS, true);
                            return;
                        }
                        if (selection.targetId == null) {
                            setStatus(activity, viewer,
                                    "Passive blocking is ready; no visible listed profile is waiting.");
                            releaseSchedulerAndContinue(
                                    schedulerToken, activity, viewer, 0L, false);
                            return;
                        }
                        new BlockRun(
                                activity, userSession, viewer, selection.targetId, forceRefresh,
                                schedulerToken).begin();
                    }
                });
                if (!posted) {
                    if (forceRefresh) {
                        requestForceRefresh(viewer);
                    }
                    setStatus(activity, viewer,
                            "Passive matching could not return to the Threads screen; reopen Threads to "
                                    + "resume safely.");
                    releaseSchedulerAndContinue(
                            schedulerToken, activity, viewer, 0L, true);
                }
            } catch (final Throwable error) {
                final Activity activity = activityRef.get();
                final Activity stateActivity = activity != null
                        ? activity : getForegroundActivity();
                if (!isSchedulerOwner(schedulerToken)) {
                    return;
                }
                if (forceRefresh) {
                    requestForceRefresh(viewer);
                }
                if (stateActivity != null) {
                    persistRetryDeadline(stateActivity, viewer);
                    setStatus(stateActivity, viewer,
                            "Passive matching stopped at a bounded local failure; retry is paused.");
                }
                Log.w(TAG, "Passive matching stopped at a bounded local failure.");
                releaseSchedulerAndContinue(
                        schedulerToken, stateActivity, viewer,
                        FAILURE_BACKOFF_MS + 1000L, true);
            }
        }
    }

    private static final class PassiveTargetSelection {
        final String targetId;
        final boolean completionReviewBlocked;
        final boolean storeBlocked;
        final boolean retrySelection;

        PassiveTargetSelection(
                String targetId,
                boolean completionReviewBlocked,
                boolean storeBlocked,
                boolean retrySelection) {
            this.targetId = targetId;
            this.completionReviewBlocked = completionReviewBlocked;
            this.storeBlocked = storeBlocked;
            this.retrySelection = retrySelection;
        }
    }

    /** Selects at most one current visible match for this independently owned drain. */
    private static PassiveTargetSelection loadTarget(
            Context context, String viewer, boolean forceRefresh)
            throws Exception {
        if (context == null || !isDecimalId(viewer) || viewer.length() > 24) {
            return new PassiveTargetSelection(null, false, false, false);
        }
        BlocklistStore.Snapshot snapshot = BlocklistStore.snapshot(context);
        long now = System.currentTimeMillis();
        if (!isUsableBlocklistSnapshot(snapshot, now)) {
            latchPassiveStorePause(context, viewer, snapshot == null ? 0L : snapshot.generation);
            return new PassiveTargetSelection(null, false, true, false);
        }
        if (isPassiveStorePaused()) {
            return new PassiveTargetSelection(null, false, true, false);
        }
        ModStateStore.CompletionReviewState review =
                ModStateStore.completionReviewState(context, viewer);
        if (!review.valid || review.full || isLocalCompletionReviewPaused(viewer)) {
            return new PassiveTargetSelection(null, true, false, false);
        }
        Set<String> done = doneIds(context, viewer);
        if (done == null) {
            return new PassiveTargetSelection(null, true, false, false);
        }

        String targetId = null;
        synchronized (PASSIVE_VISIBILITY_LOCK) {
            for (Map.Entry<String, Long> entry : PASSIVE_MATCH_GENERATIONS.entrySet()) {
                String candidate = passiveTargetFromKey(entry.getKey(), viewer);
                if (candidate != null
                        && entry.getValue().longValue() == snapshot.generation
                        && hasVisibleRegistrationLocked(viewer, candidate)
                        && !viewer.equals(candidate)
                        && !done.contains(candidate)
                        && !review.targets.contains(candidate)) {
                    targetId = candidate;
                    break;
                }
            }
        }
        if (targetId == null) {
            setStatus(context, viewer,
                    "Passive blocking is ready; no visible listed profile is waiting.");
            return new PassiveTargetSelection(null, false, false, false);
        }
        BlocklistStore.IdMatch match = BlocklistStore.lookupId(context, targetId);
        if (match.storeValid && match.matched
                && match.generation == snapshot.generation
                && visibleUsernameMatchesStored(viewer, targetId, match.username)) {
            setStatus(context, viewer,
                    "Passive blocking found one current visible indexed match.");
            return new PassiveTargetSelection(targetId, false, false, false);
        }
        if (!match.storeValid) {
            latchPassiveStorePause(context, viewer, match.generation);
            return new PassiveTargetSelection(null, false, true, false);
        }
        synchronized (PASSIVE_VISIBILITY_LOCK) {
            String key = passiveKey(viewer, targetId);
            Long generation = PASSIVE_MATCH_GENERATIONS.get(key);
            if (generation != null && generation.longValue() == snapshot.generation) {
                PASSIVE_MATCH_GENERATIONS.remove(key);
            }
        }
        return new PassiveTargetSelection(null, false, false, true);
    }

    private static void requestListRefresh(
            Activity activity, String viewer, boolean forceRefresh) {
        if (activity == null || !isDecimalId(viewer) || viewer.length() > 24
                || !isEnabled(activity)) {
            return;
        }
        long requestNow = System.currentTimeMillis();
        boolean forcedIntent = forceRefresh || hasListForceRefresh(viewer);
        if (!forcedIntent) {
            DeadlineState deadline = readListRefreshDeadline(activity, requestNow);
            if (!deadline.valid) {
                listRefreshPhase = LIST_PHASE_INVALID;
                String status = "List-refresh timing state needs review; ordinary refresh remains paused.";
                setStatus(activity, viewer, status);
                ModStateStore.recordRuntimeState(
                        activity, viewer, "blocklist_refresh_deadline_invalid", status, true);
                armListRefreshWake(activity, viewer, FETCH_INTERVAL_MS);
                return;
            }
            // Once per foreground session, while no verified index exists and at least one
            // ladder step after the last admitted start, the first ordinary request starts
            // ahead of a pending deadline instead of waiting it out. The 600,000 ms guard is
            // still installed below before work starts.
            boolean missingIndexStart = deadline.value > requestNow
                    && consumeMissingIndexResumeStart(activity, requestNow);
            if (!missingIndexStart) {
                if (deadline.value > requestNow) {
                    armListRefreshWake(activity, viewer, deadline.value - requestNow);
                    return;
                }
            }
        }
        if (!LIST_REFRESH_RUNNING.compareAndSet(false, true)) {
            if (forceRefresh && !requestListForceRefresh(viewer)) {
                setStatus(activity, viewer,
                        "Forced list refresh is waiting behind an active refresh, but its bounded "
                                + "viewer queue is full; existing requests were preserved.");
            }
            return;
        }
        boolean runForced = forceRefresh;
        if (!runForced && hasListForceRefresh(viewer)) {
            runForced = consumeListForceRefresh(viewer);
        }
        if (!advanceListRefreshDeadline(activity, System.currentTimeMillis())) {
            LIST_REFRESH_RUNNING.set(false);
            listRefreshPhase = LIST_PHASE_INVALID;
            if (runForced) {
                requestListForceRefresh(viewer);
            }
            String status = "List-refresh timing could not be saved; refresh remains paused fail-closed.";
            setStatus(activity, viewer, status);
            ModStateStore.recordRuntimeState(
                    activity, viewer, "blocklist_refresh_deadline_persistence", status, true);
            armListRefreshWake(activity, viewer, FETCH_INTERVAL_MS);
            return;
        }
        listRefreshResumeStartPending = false;
        listRefreshLastStartMs = System.currentTimeMillis();
        listRefreshFailureSummary = "";
        listRefreshPhase = LIST_PHASE_FETCHING;
        try {
            Thread worker = new Thread(
                    new ListRefreshWorker(activity, viewer, runForced),
                    "ThreadsModBlocklistRefresh");
            worker.start();
        } catch (Throwable ignored) {
            boolean deadlineSaved = advanceListRefreshDeadline(
                    activity, System.currentTimeMillis());
            LIST_REFRESH_RUNNING.set(false);
            listRefreshPhase = LIST_PHASE_RETAINED_ERROR;
            boolean forceRetained = !runForced || requestListForceRefresh(viewer);
            String status = !deadlineSaved
                    ? "List refresh worker could not start and its next-wake time could not be saved; refresh is paused."
                    : forceRetained
                            ? "List refresh worker could not start; retry is retained for a later wake."
                            : "List refresh worker could not start and the bounded force queue is full; "
                                    + "existing viewer requests were preserved.";
            setStatus(activity, viewer, status);
            ModStateStore.recordRuntimeState(
                    activity, viewer,
                    deadlineSaved ? "blocklist_refresh_worker_start_rejected"
                            : "blocklist_refresh_deadline_persistence",
                    status, true);
            armListRefreshWake(
                    activity, viewer, millisUntilNextListRefresh(activity));
        }
    }

    private static void armListRefreshWake(
            Activity activity, String viewer, long delayMs) {
        MAIN.removeCallbacks(LIST_REFRESH_WAKE);
        if (activity == null || !isDecimalId(viewer) || viewer.length() > 24
                || !foreground || !isEnabled(activity)) {
            return;
        }
        boolean posted = MAIN.postDelayed(
                LIST_REFRESH_WAKE, Math.max(1000L, delayMs));
        if (!posted) {
            setStatus(activity, viewer,
                    "The list refresh wake was rejected; reopen Threads to retry.");
            ModStateStore.recordRuntimeState(
                    activity, viewer, "blocklist_refresh_wake_rejected",
                    "Passive list refresh is paused until Threads resumes.", true);
        }
    }

    private static final class ListRefreshWorker implements Runnable {
        private final WeakReference<Activity> activityRef;
        private final String viewer;
        private final boolean forced;

        ListRefreshWorker(Activity activity, String viewer, boolean forced) {
            this.activityRef = new WeakReference<Activity>(activity);
            this.viewer = viewer;
            this.forced = forced;
        }

        @Override
        public void run() {
            final Activity activity = activityRef.get();
            String status;
            boolean failure = false;
            try {
                if (activity == null) {
                    throw new IllegalStateException("foreground activity unavailable");
                }
                status = refreshBlocklist(activity.getApplicationContext(), forced);
                scheduleVisibleRegistrationRescan(activity.getApplicationContext());
            } catch (Throwable error) {
                failure = true;
                listRefreshPhase = LIST_PHASE_RETAINED_ERROR;
                String failures = listRefreshFailureSummary;
                status = "List refresh failed"
                        + (failures.length() > 0 ? " (" + failures + ")" : "")
                        + "; the previous verified database, if any, was preserved.";
                Log.w(TAG, "Passive list refresh stopped at a bounded local failure.");
            }
            // A successful attempt re-installs the ordinary 600,000 ms deadline; a failed one
            // installs the next bounded ladder step so recovery is quick, then the ordinary
            // cadence once the per-session ladder is exhausted.
            long nextIntervalMs;
            if (failure) {
                nextIntervalMs = recordListRefreshFailureAndNextIntervalMs();
            } else {
                resetListRefreshFailureLadder();
                nextIntervalMs = FETCH_INTERVAL_MS;
            }
            if (activity == null
                    || !advanceListRefreshDeadline(
                            activity.getApplicationContext(), System.currentTimeMillis(),
                            nextIntervalMs)) {
                failure = true;
                listRefreshPhase = LIST_PHASE_RETAINED_ERROR;
                status = "List refresh ended, but its next-wake time could not be saved; refresh is paused.";
            }
            LIST_REFRESH_RUNNING.set(false);
            final String resultStatus = status;
            final boolean resultFailure = failure;
            boolean posted = MAIN.post(new Runnable() {
                @Override
                public void run() {
                    Activity active = getForegroundActivity();
                    String activeViewer = getCurrentViewer();
                    if (active != null && viewer.equals(activeViewer)
                            && isEnabled(active)) {
                        setStatus(active, viewer, resultStatus);
                        ModStateStore.recordRuntimeState(
                                active, viewer,
                                resultFailure ? "blocklist_refresh_failed"
                                        : "blocklist_refresh_complete",
                                resultStatus, resultFailure);
                        armListRefreshWake(
                                active, viewer,
                                millisUntilNextListRefresh(active));
                    }
                    if (active != null && activeViewer != null && isEnabled(active)
                            && hasListForceRefresh(activeViewer)) {
                        consumeListForceRefresh(activeViewer);
                        requestListRefresh(active, activeViewer, true);
                    }
                }
            });
            if (!posted && activity != null) {
                setStatus(activity, viewer,
                        "List refresh completed off-screen; reopen Threads to resume passive checks.");
            }
        }
    }

    private static String refreshBlocklist(Context context, boolean forceRefresh)
            throws Exception {
        BlocklistStore.Snapshot snapshot = BlocklistStore.snapshot(context);
        long now = System.currentTimeMillis();
        if (!forceRefresh && isUsableBlocklistSnapshot(snapshot, now)
                && now >= snapshot.fetchedAtMs
                && now - snapshot.fetchedAtMs < FETCH_INTERVAL_MS) {
            listRefreshPhase = LIST_PHASE_READY;
            return "Indexed block list is current (" + snapshot.targetCount + " profiles).";
        }

        CloneBlockerEndpoints.validateConfiguration();
        Exception lastError = null;
        VerifiedList best = null;
        String[] mirrorFailures = new String[CloneBlockerEndpoints.blocklistMirrorCount()];
        // Every allowlisted mirror is consulted in declared order and verified on its
        // own. The candidate with the strictly newest signed updatedAt wins; an equal
        // timestamp keeps the earlier mirror. A stale but reachable mirror can no
        // longer hide a newer verified snapshot behind a first-success return or a
        // conditional 304 short-circuit.
        for (int mirror = 0; mirror < CloneBlockerEndpoints.blocklistMirrorCount(); mirror++) {
            try {
                listRefreshPhase = LIST_PHASE_FETCHING;
                VerifiedList candidate = fetchMirror(context, forceRefresh, mirror, snapshot);
                if (candidate != null
                        && (best == null || candidate.publishedAtMs > best.publishedAtMs)) {
                    best = candidate;
                }
            } catch (Exception fetchError) {
                lastError = fetchError;
                mirrorFailures[mirror] = classifyListFetchFailure(fetchError);
                Log.w(TAG, "Signed-list mirror " + (mirror + 1)
                        + " failed with a bounded local error.");
            }
        }
        if (best != null) {
            return installVerifiedCandidate(context, best, snapshot);
        }
        // Published before this method throws, so a status reader that observes the retained
        // error phase also observes the per-mirror classes of this attempt.
        listRefreshFailureSummary = describeMirrorFailures(mirrorFailures);
        BlocklistStore.Snapshot retained = BlocklistStore.snapshot(context);
        if (isUsableBlocklistSnapshot(retained, System.currentTimeMillis())) {
            if (lastError != null) {
                throw lastError;
            }
            throw new IllegalStateException(
                    "public mirrors failed while a prior verified generation was retained");
        }
        if (lastError != null) {
            throw lastError;
        }
        throw new IllegalStateException("no blocklist mirror is configured");
    }

    /**
     * Fetches and verifies one allowlisted mirror without installing anything. A 304 is
     * accepted only from the exact mirror that produced the retained generation while that
     * generation is still usable; every other request is unconditional.
     */
    private static VerifiedList fetchMirror(
            Context context,
            boolean forceRefresh,
            int mirror,
            BlocklistStore.Snapshot previousSnapshot)
            throws Exception {
        URL url = CloneBlockerEndpoints.manifestUrl(mirror);
        // One immediate retry per mirror, only after a transport failure (the IOException
        // family: connect/read timeout, DNS or connect failure, TLS failure, or a stream that
        // broke mid-body). An HTTP status, oversized body, cookie refusal, or verification
        // failure is never retried within the attempt. Each try is a fresh connection.
        try {
            return fetchMirrorOnce(context, forceRefresh, mirror, url, previousSnapshot);
        } catch (Exception firstError) {
            if (!isTransportFailure(firstError)) {
                throw firstError;
            }
            Log.w(TAG, "Signed-list mirror " + (mirror + 1)
                    + " is retried once after a transport failure.");
        }
        return fetchMirrorOnce(context, forceRefresh, mirror, url, previousSnapshot);
    }

    private static VerifiedList fetchMirrorOnce(
            Context context,
            boolean forceRefresh,
            int mirror,
            URL url,
            BlocklistStore.Snapshot previousSnapshot)
            throws Exception {
        SharedPreferences p = prefs(context);
        String exactUrl = url.toExternalForm();
        HttpsURLConnection connection = null;
        boolean conditionalRequest = false;
        try {
            if (CookieHandler.getDefault() != null) {
                throw new ListFetchFailure(FAILURE_COOKIE_REFUSED,
                        "list fetch refused while a process-wide CookieHandler is installed");
            }
            connection = (HttpsURLConnection) url.openConnection();
            connection.setConnectTimeout(10000);
            connection.setReadTimeout(15000);
            connection.setInstanceFollowRedirects(false);
            connection.setUseCaches(false);
            connection.setRequestMethod("GET");
            connection.setRequestProperty("Accept", "application/json");
            if (!forceRefresh && exactUrl.equals(p.getString(KEY_ETAG_URL, ""))
                    && isUsableBlocklistSnapshot(previousSnapshot, System.currentTimeMillis())) {
                String etag = p.getString(KEY_ETAG, "");
                if (etag != null && etag.length() > 0 && etag.length() <= 1024) {
                    connection.setRequestProperty("If-None-Match", etag);
                    conditionalRequest = true;
                }
            }

            if (CookieHandler.getDefault() != null) {
                throw new ListFetchFailure(FAILURE_COOKIE_REFUSED,
                        "list fetch refused before connect because cookies could be inherited");
            }

            int status = connection.getResponseCode();
            long fetchedNow = System.currentTimeMillis();
            if (status == HttpsURLConnection.HTTP_NOT_MODIFIED) {
                if (!conditionalRequest
                        || !isUsableBlocklistSnapshot(previousSnapshot, fetchedNow)) {
                    throw new ListFetchFailure(httpFailureClass(status),
                            "mirror returned 304 without its valid conditional cache");
                }
                return VerifiedList.unchanged(previousSnapshot, mirror, exactUrl, fetchedNow);
            }
            if (status != HttpsURLConnection.HTTP_OK) {
                throw new ListFetchFailure(httpFailureClass(status),
                        "list mirror rejected the request");
            }

            int contentLength = connection.getContentLength();
            if (contentLength > MAX_RESPONSE_BYTES) {
                throw new ListFetchFailure(FAILURE_TOO_LARGE, "list response is too large");
            }
            String etag = connection.getHeaderField("ETag");
            String body;
            InputStream input = connection.getInputStream();
            try {
                body = readBounded(input, contentLength);
            } finally {
                input.close();
            }

            listRefreshPhase = LIST_PHASE_VERIFYING;
            VerifiedList verified = parseAndVerify(
                    body,
                    previousSnapshot.valid ? previousSnapshot.verifiedUpdatedAtMs : 0L);
            return verified.fetched(mirror, exactUrl, etag, fetchedNow);
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    /**
     * Installs the single freshest verified candidate chosen across all mirrors: a 304
     * re-confirmation advances only fetch metadata, while a verified payload atomically
     * replaces one indexed generation and rebinds the conditional cache to its mirror.
     */
    private static String installVerifiedCandidate(
            Context context,
            VerifiedList best,
            BlocklistStore.Snapshot previousSnapshot)
            throws Exception {
        SharedPreferences p = prefs(context);
        // Only a strictly newer verified payload may replace the committed generation. A 304, or a
        // reachable mirror still serving the timestamp already indexed, advances fetch metadata
        // only, so an equal replacement can neither churn the index nor clear the passive latch.
        boolean retainedUsable = previousSnapshot.valid
                && isUsableBlocklistSnapshot(previousSnapshot, best.fetchedAtMs);
        if (best.unchanged
                || retainedUsable
                        && best.publishedAtMs <= previousSnapshot.verifiedUpdatedAtMs) {
            if (!BlocklistStore.markFetchedUnchanged(context, best.fetchedAtMs)) {
                throw new IllegalStateException("could not persist refreshed list time");
            }
            clearLegacyListPreferences(p);
            listRefreshPhase = LIST_PHASE_UNCHANGED;
            return "Signed block list is unchanged ("
                    + previousSnapshot.targetCount + " indexed profiles).";
        }

        // Group tables and gzip NDJSON chunks are fetched, bound to the signed root, and
        // staged by ChunkInstaller; only its typed per-mirror tokens may reach status text.
        BlocklistStore.InstallPlan plan;
        try {
            plan = ChunkInstaller.stage(context, best, previousSnapshot);
        } catch (ObjectFetcher.StageFailure objectFailure) {
            listRefreshFailureSummary = describeMirrorFailures(objectFailure.mirrorFailures);
            throw new ListFetchFailure(objectFailure.failureClass,
                    "signed objects could not be staged");
        }

        boolean replaced;
        BlocklistStore.Snapshot installed;
        listRefreshPhase = LIST_PHASE_INDEXING;
        synchronized (PASSIVE_ADMISSION_LOCK) {
            replaced = BlocklistStore.replaceVerified(
                    context, plan, best.updatedAt, best.publishedAtMs, best.fetchedAtMs);
            installed = replaced ? BlocklistStore.snapshot(context) : null;
            if (replaced && (installed == null || !installed.valid
                    || installed.generation < 1L
                    || previousSnapshot.valid
                            && installed.generation <= previousSnapshot.generation)) {
                replaced = false;
            }
            if (replaced) {
                clearPassiveStorePauseAfterVerifiedGeneration(installed.generation);
            }
        }
        if (!replaced) {
            throw new IllegalStateException("could not atomically replace verified list");
        }
        SharedPreferences.Editor edit = p.edit()
                .remove(LEGACY_KEY_FETCHED_AT)
                .remove(LEGACY_KEY_UPDATED_AT)
                .remove(LEGACY_KEY_CACHE_VALID)
                .remove(LEGACY_KEY_TARGET_CACHE);
        if (best.etag != null && best.etag.length() > 0 && best.etag.length() <= 1024) {
            edit.putString(KEY_ETAG, best.etag).putString(KEY_ETAG_URL, best.exactUrl);
        } else {
            edit.remove(KEY_ETAG).remove(KEY_ETAG_URL);
        }
        boolean conditionalMetadataSaved = false;
        try {
            conditionalMetadataSaved = edit.commit();
        } catch (Throwable ignored) {
            // The signed SQLite generation is already authoritative; ETag state is optional.
        }
        listRefreshPhase = LIST_PHASE_READY;
        return "Verified and indexed " + installed.targetCount
                + " Threads profiles from a public mirror."
                + (conditionalMetadataSaved
                        ? ""
                        : " Conditional fetch metadata will retry later.");
    }

    private static void clearLegacyListPreferences(SharedPreferences p) {
        p.edit()
                .remove(LEGACY_KEY_FETCHED_AT)
                .remove(LEGACY_KEY_UPDATED_AT)
                .remove(LEGACY_KEY_CACHE_VALID)
                .remove(LEGACY_KEY_TARGET_CACHE)
                .apply();
    }

    /**
     * Reads the whole body under MAX_RESPONSE_BYTES. Content-Length is only a sizing hint
     * (it is -1 for chunked bodies); the cap is enforced on the bytes actually read.
     */
    private static String readBounded(InputStream input, int sizeHint) throws Exception {
        int initialCapacity = sizeHint > 0 && sizeHint <= MAX_RESPONSE_BYTES
                ? sizeHint : 64 * 1024;
        ByteArrayOutputStream output = new ByteArrayOutputStream(initialCapacity);
        byte[] buffer = new byte[16 * 1024];
        int total = 0;
        while (true) {
            int read = input.read(buffer);
            if (read < 0) {
                break;
            }
            total += read;
            if (total > MAX_RESPONSE_BYTES) {
                throw new ListFetchFailure(FAILURE_TOO_LARGE,
                        "list response exceeds the local byte cap");
            }
            output.write(buffer, 0, read);
        }
        return new String(output.toByteArray(), StandardCharsets.UTF_8);
    }

    private static VerifiedList parseAndVerify(String body, long previousPublishedAt)
            throws Exception {
        if (body.length() > MAX_ROOT_BYTES) {
            throw new ListFetchFailure(FAILURE_TOO_LARGE,
                    "signed root exceeds the local byte cap");
        }
        JSONObject envelope = new JSONObject(body);
        if (!"ed25519".equalsIgnoreCase(envelope.optString("alg", ""))) {
            throw new ListFetchFailure(FAILURE_SIGNATURE,
                    "list signature algorithm is not Ed25519");
        }
        String signature = envelope.optString("sig", "");
        if (signature.length() < 40 || signature.length() > 160) {
            throw new ListFetchFailure(FAILURE_SIGNATURE,
                    "list signature is missing or malformed");
        }

        String payloadJson = extractPayloadJson(body);
        if (payloadJson == null || payloadJson.length() == 0) {
            throw new ListFetchFailure(FAILURE_SCHEMA, "signed payload is missing");
        }
        boolean signatureValid;
        try {
            signatureValid = verifySignature(payloadJson, signature);
        } catch (IllegalArgumentException malformedEncoding) {
            // Base64 rejected the signature text; that is a signature failure, not a fault.
            signatureValid = false;
        }
        if (!signatureValid) {
            throw new ListFetchFailure(FAILURE_SIGNATURE, "list signature verification failed");
        }

        JSONObject payload = new JSONObject(payloadJson);
        String updatedAt = payload.optString("updatedAt", "");
        long publishedAt = parseInstant(updatedAt);
        if (publishedAt <= 0L) {
            throw new ListFetchFailure(FAILURE_SCHEMA, "signed list has no valid updatedAt");
        }
        long now = System.currentTimeMillis();
        if (publishedAt > now + 24L * 60L * 60L * 1000L) {
            throw new ListFetchFailure(FAILURE_CLOCK, "signed list timestamp is in the future");
        }
        if (publishedAt < now - SIGNED_LIST_MAX_AGE_MS) {
            throw new ListFetchFailure(FAILURE_STALE, "signed list is older than 30 days");
        }
        if (previousPublishedAt > 0L && publishedAt < previousPublishedAt) {
            throw new ListFetchFailure(FAILURE_ROLLBACK, "signed list rollback rejected");
        }

        // Chunked v3 root: only the bucket geometry and the content-addressed group tables
        // live here; the rows arrive as gzip NDJSON chunks that ChunkInstaller fetches and
        // stages. Every field is read type-strictly because org.json coerces on optInt.
        Object versionValue = payload.opt("v");
        if (!(versionValue instanceof Integer) || ((Integer) versionValue).intValue() != 3) {
            throw new ListFetchFailure(FAILURE_SCHEMA, "signed root is not v3");
        }
        Object hashValue = payload.opt("hash");
        if (!(hashValue instanceof String) || !"sha256-hi32".equals((String) hashValue)) {
            throw new ListFetchFailure(FAILURE_SCHEMA,
                    "signed root bucket function is not sha256-hi32");
        }
        Object maxChunkRowsValue = payload.opt("maxChunkRows");
        Object maxChunkBytesValue = payload.opt("maxChunkBytes");
        if (!(maxChunkRowsValue instanceof Integer)
                || !(maxChunkBytesValue instanceof Integer)) {
            throw new ListFetchFailure(FAILURE_SCHEMA, "signed root chunk caps are malformed");
        }
        int maxChunkRows = ((Integer) maxChunkRowsValue).intValue();
        int maxChunkBytes = ((Integer) maxChunkBytesValue).intValue();
        if (maxChunkRows < 1 || maxChunkBytes < 1) {
            throw new ListFetchFailure(FAILURE_SCHEMA, "signed root chunk caps are malformed");
        }
        if (maxChunkRows > MAX_CHUNK_ROWS || maxChunkBytes > MAX_CHUNK_GZ_BYTES) {
            throw new ListFetchFailure(FAILURE_TOO_LARGE,
                    "signed root chunk caps exceed the local caps");
        }
        Object platformsValue = payload.opt("platforms");
        Object threadsValue = platformsValue instanceof JSONObject
                ? ((JSONObject) platformsValue).opt("threads") : null;
        if (!(threadsValue instanceof JSONObject)) {
            throw new ListFetchFailure(FAILURE_SCHEMA, "signed root has no threads partition");
        }
        JSONObject threads = (JSONObject) threadsValue;
        Object bucketBitsValue = threads.opt("k");
        Object groupBitsValue = threads.opt("g");
        Object totalValue = threads.opt("total");
        Object groupsValue = threads.opt("groups");
        if (!(bucketBitsValue instanceof Integer)
                || !(groupBitsValue instanceof Integer)
                || !(totalValue instanceof Integer)
                || !(groupsValue instanceof JSONArray)) {
            throw new ListFetchFailure(FAILURE_SCHEMA,
                    "signed root threads partition is malformed");
        }
        int bucketBits = ((Integer) bucketBitsValue).intValue();
        int groupBits = ((Integer) groupBitsValue).intValue();
        int total = ((Integer) totalValue).intValue();
        if (bucketBits < 0 || groupBits < 0 || total < 0) {
            throw new ListFetchFailure(FAILURE_SCHEMA,
                    "signed root threads partition is malformed");
        }
        if (bucketBits > MAX_BUCKET_BITS || groupBits > MAX_GROUP_BITS) {
            throw new ListFetchFailure(FAILURE_TARGET_CAP,
                    "signed root exceeds the local bucket cap");
        }
        if (groupBits > bucketBits) {
            throw new ListFetchFailure(FAILURE_SCHEMA,
                    "signed root threads partition is malformed");
        }
        if (total > MAX_INDEX_ROWS) {
            throw new ListFetchFailure(FAILURE_TARGET_CAP,
                    "signed root exceeds the local row cap");
        }
        JSONArray groupTable = (JSONArray) groupsValue;
        int groupCount = 1 << groupBits;
        if (groupTable.length() != groupCount) {
            throw new ListFetchFailure(FAILURE_SCHEMA,
                    "signed root threads partition is malformed");
        }
        String[] groups = new String[groupCount];
        for (int i = 0; i < groupCount; i++) {
            Object groupValue = groupTable.opt(i);
            if (!(groupValue instanceof String)
                    || !isLowercaseHexDigest((String) groupValue)) {
                throw new ListFetchFailure(FAILURE_SCHEMA,
                        "signed root threads partition is malformed");
            }
            groups[i] = (String) groupValue;
        }
        return new VerifiedList(
                updatedAt, publishedAt, bucketBits, groupBits, total,
                maxChunkRows, maxChunkBytes, groups);
    }

    private static boolean verifySignature(String payloadJson, String encodedSignature)
            throws Exception {
        byte[] encodedKey = Base64.decode(
                LIST_KEY_RAW,
                Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP);
        byte[] signature = Base64.decode(
                encodedSignature,
                Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP);
        if (encodedKey.length != 32 || signature.length != 64) {
            return false;
        }
        EdDSAPublicKey key = new EdDSAPublicKey(
                new EdDSAPublicKeySpec(
                        encodedKey,
                        EdDSANamedCurveTable.ED_25519_CURVE_SPEC));
        EdDSAEngine verifier = new EdDSAEngine();
        verifier.initVerify(key);
        return verifier.verifyOneShot(
                payloadJson.getBytes(StandardCharsets.UTF_8),
                signature);
    }

    /** Extracts the exact compact JSON bytes the extension/server signed. */
    private static String extractPayloadJson(String document) {
        int key = document.indexOf("\"payload\"");
        if (key < 0) {
            return null;
        }
        int colon = document.indexOf(':', key + 9);
        if (colon < 0) {
            return null;
        }
        int start = colon + 1;
        while (start < document.length() && Character.isWhitespace(document.charAt(start))) {
            start++;
        }
        if (start >= document.length()) {
            return null;
        }
        int end = scanJsonValue(document, start);
        if (end <= start) {
            return null;
        }
        return document.substring(start, end);
    }

    private static int scanJsonValue(String text, int start) {
        char first = text.charAt(start);
        if (first == '{' || first == '[') {
            int depth = 0;
            boolean inString = false;
            boolean escaped = false;
            for (int i = start; i < text.length(); i++) {
                char c = text.charAt(i);
                if (inString) {
                    if (escaped) {
                        escaped = false;
                    } else if (c == '\\') {
                        escaped = true;
                    } else if (c == '"') {
                        inString = false;
                    }
                    continue;
                }
                if (c == '"') {
                    inString = true;
                } else if (c == '{' || c == '[') {
                    depth++;
                } else if (c == '}' || c == ']') {
                    depth--;
                    if (depth == 0) {
                        return i + 1;
                    }
                }
            }
            return -1;
        }
        if (first == '"') {
            boolean escaped = false;
            for (int i = start + 1; i < text.length(); i++) {
                char c = text.charAt(i);
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    return i + 1;
                }
            }
            return -1;
        }
        int i = start;
        while (i < text.length() && text.charAt(i) != ',' && text.charAt(i) != '}') {
            i++;
        }
        return i;
    }

    /**
     * One signed, verified v3 root. It carries the bucket geometry and the content-addressed
     * group-table names only; the rows themselves are staged by ChunkInstaller.
     */
    static final class VerifiedList {
        final String updatedAt;
        final long publishedAtMs;
        /** Bucket = high {@code bucketBits} bits of sha256(key); 0 puts every row in bucket 0. */
        final int bucketBits;
        /** Group = high {@code groupBits} bits of the bucket; {@code groups.length == 1 << groupBits}. */
        final int groupBits;
        final int total;
        final int maxChunkRows;
        final int maxChunkBytes;
        /** Lowercase SHA-256 hex names of the group tables, or null on an unchanged candidate. */
        final String[] groups;
        /** Allowlisted mirror index that produced this candidate, or -1 before fetch binding. */
        final int mirror;
        final String exactUrl;
        final String etag;
        final long fetchedAtMs;
        /** True for a conditional 304 that only re-confirms the retained verified generation. */
        final boolean unchanged;

        VerifiedList(
                String updatedAt,
                long publishedAtMs,
                int bucketBits,
                int groupBits,
                int total,
                int maxChunkRows,
                int maxChunkBytes,
                String[] groups) {
            this(updatedAt, publishedAtMs, bucketBits, groupBits, total, maxChunkRows,
                    maxChunkBytes, groups, -1, null, null, 0L, false);
        }

        private VerifiedList(
                String updatedAt,
                long publishedAtMs,
                int bucketBits,
                int groupBits,
                int total,
                int maxChunkRows,
                int maxChunkBytes,
                String[] groups,
                int mirror,
                String exactUrl,
                String etag,
                long fetchedAtMs,
                boolean unchanged) {
            this.updatedAt = updatedAt;
            this.publishedAtMs = publishedAtMs;
            this.bucketBits = bucketBits;
            this.groupBits = groupBits;
            this.total = total;
            this.maxChunkRows = maxChunkRows;
            this.maxChunkBytes = maxChunkBytes;
            this.groups = groups;
            this.mirror = mirror;
            this.exactUrl = exactUrl;
            this.etag = etag;
            this.fetchedAtMs = fetchedAtMs;
            this.unchanged = unchanged;
        }

        VerifiedList fetched(int mirror, String exactUrl, String etag, long fetchedAtMs) {
            return new VerifiedList(
                    updatedAt, publishedAtMs, bucketBits, groupBits, total, maxChunkRows,
                    maxChunkBytes, groups, mirror, exactUrl, etag, fetchedAtMs, false);
        }

        static VerifiedList unchanged(
                BlocklistStore.Snapshot previous, int mirror, String exactUrl, long fetchedAtMs) {
            return new VerifiedList(
                    previous.verifiedUpdatedAt, previous.verifiedUpdatedAtMs,
                    0, 0, 0, 0, 0, null, mirror, exactUrl, null, fetchedAtMs, true);
        }
    }

    private static final class PassiveRegistration {
        final String viewer;
        final String rowKey;
        final String targetId;
        final String username;
        boolean visible;

        PassiveRegistration(
                String viewer, String rowKey, String targetId, String username) {
            this.viewer = viewer;
            this.rowKey = rowKey;
            this.targetId = targetId;
            this.username = username;
        }
    }

    private static final class PassiveMatchResult {
        final boolean storeValid;
        final boolean matched;

        PassiveMatchResult(boolean storeValid, boolean matched) {
            this.storeValid = storeValid;
            this.matched = matched;
        }
    }

    private static final class PassiveAuthority {
        final boolean allowed;
        final boolean resume;
        final boolean foregroundChanged;
        final long delayMs;
        final String status;

        private PassiveAuthority(
                boolean allowed,
                boolean resume,
                boolean foregroundChanged,
                long delayMs,
                String status) {
            this.allowed = allowed;
            this.resume = resume;
            this.foregroundChanged = foregroundChanged;
            this.delayMs = delayMs;
            this.status = status;
        }

        static PassiveAuthority allowed() {
            return new PassiveAuthority(true, false, false, 0L, "");
        }

        static PassiveAuthority pause(String status) {
            return new PassiveAuthority(false, false, false, 0L, status);
        }

        static PassiveAuthority resume(String status, long delayMs) {
            return new PassiveAuthority(
                    false, true, false, Math.max(0L, delayMs), status);
        }

        static PassiveAuthority foregroundChanged(String status) {
            return new PassiveAuthority(false, false, true, 0L, status);
        }
    }

    private static final class PassiveLookupWorker implements Runnable {
        private final Context context;

        PassiveLookupWorker(Context context) {
            this.context = context.getApplicationContext();
        }

        @Override
        public void run() {
            boolean matchedAny = false;
            try {
                while (true) {
                    String key;
                    String viewer;
                    String targetId;
                    synchronized (PASSIVE_VISIBILITY_LOCK) {
                        key = PASSIVE_LOOKUP_QUEUE.pollFirst();
                        if (key == null) {
                            break;
                        }
                        PASSIVE_LOOKUP_QUEUED.remove(key);
                        viewer = passiveViewerFromKey(key);
                        targetId = passiveTargetFromKey(key, viewer);
                        if (viewer == null || targetId == null
                                || !hasVisibleRegistrationLocked(viewer, targetId)) {
                            PASSIVE_MATCH_GENERATIONS.remove(key);
                            continue;
                        }
                    }

                    BlocklistStore.IdMatch match = BlocklistStore.lookupId(context, targetId);
                    if (!match.storeValid) {
                        latchPassiveStorePause(context, viewer, match.generation);
                        break;
                    }
                    synchronized (PASSIVE_VISIBILITY_LOCK) {
                        if (!hasVisibleRegistrationLocked(viewer, targetId)) {
                            PASSIVE_MATCH_GENERATIONS.remove(key);
                        } else if (match.matched
                                && visibleUsernameMatchesStoredLocked(
                                        viewer, targetId, match.username)) {
                            if (PASSIVE_MATCH_GENERATIONS.containsKey(key)
                                    || PASSIVE_MATCH_GENERATIONS.size()
                                            < MAX_PASSIVE_MATCHES) {
                                PASSIVE_MATCH_GENERATIONS.put(
                                        key, Long.valueOf(match.generation));
                                matchedAny = true;
                            }
                        } else {
                            PASSIVE_MATCH_GENERATIONS.remove(key);
                        }
                    }
                }
            } finally {
                PASSIVE_LOOKUP_RUNNING.set(false);
            }

            if (matchedAny) {
                boolean posted = MAIN.post(new Runnable() {
                    @Override
                    public void run() {
                        scheduleManualDrain(0L);
                    }
                });
                if (!posted) {
                    Activity activity = getForegroundActivity();
                    String viewer = getCurrentViewer();
                    if (activity != null && viewer != null) {
                        setStatus(activity, viewer,
                                "A passive match is waiting; reopen Threads to resume safely.");
                    }
                }
            }

            synchronized (PASSIVE_VISIBILITY_LOCK) {
                if (!isPassiveStorePaused() && !PASSIVE_LOOKUP_QUEUE.isEmpty()) {
                    startPassiveLookupWorker(context);
                }
            }
        }
    }

    private static void startPassiveLookupWorker(Context context) {
        if (context == null || isPassiveStorePaused()
                || !PASSIVE_LOOKUP_RUNNING.compareAndSet(false, true)) {
            return;
        }
        try {
            Thread worker = new Thread(
                    new PassiveLookupWorker(context), "ThreadsModPassiveLookup");
            worker.start();
        } catch (Throwable ignored) {
            PASSIVE_LOOKUP_RUNNING.set(false);
            Activity activity = getForegroundActivity();
            String viewer = getCurrentViewer();
            if (activity != null && viewer != null) {
                setStatus(activity, viewer,
                        "Indexed visibility lookup could not start; reopen Threads to retry.");
                ModStateStore.recordRuntimeState(
                        activity, viewer, "passive_lookup_worker_start_rejected",
                        "Visible matches remain paused until a later foreground rescan.", true);
            }
        }
    }

    private static void scheduleVisibleRegistrationRescan(Context context) {
        if (context == null || isPassiveStorePaused()) {
            return;
        }
        synchronized (PASSIVE_VISIBILITY_LOCK) {
            PASSIVE_MATCH_GENERATIONS.clear();
            for (PassiveRegistration registration : PASSIVE_REGISTRATIONS.values()) {
                if (registration.visible) {
                    enqueuePassiveLookupLocked(
                            passiveKey(registration.viewer, registration.targetId));
                }
            }
        }
        startPassiveLookupWorker(context);
    }

    private static void enqueuePassiveLookupLocked(String key) {
        if (key == null || PASSIVE_LOOKUP_QUEUED.contains(key)
                || PASSIVE_LOOKUP_QUEUE.size() >= MAX_PASSIVE_LOOKUP_QUEUE) {
            return;
        }
        PASSIVE_LOOKUP_QUEUE.addLast(key);
        PASSIVE_LOOKUP_QUEUED.add(key);
    }

    private static void removeQueuedPassiveLookupLocked(String key) {
        if (key != null && PASSIVE_LOOKUP_QUEUED.remove(key)) {
            PASSIVE_LOOKUP_QUEUE.remove(key);
        }
    }

    private static void removePassiveRegistrationLocked(
            Object token, PassiveRegistration registration) {
        PASSIVE_REGISTRATIONS.remove(token);
        if (registration.visible
                && !hasVisibleRegistrationLocked(
                        registration.viewer, registration.targetId)) {
            String key = passiveKey(registration.viewer, registration.targetId);
            PASSIVE_MATCH_GENERATIONS.remove(key);
            removeQueuedPassiveLookupLocked(key);
        }
    }

    private static boolean hasVisibleRegistrationLocked(
            String viewer, String targetId) {
        for (PassiveRegistration registration : PASSIVE_REGISTRATIONS.values()) {
            if (registration.visible
                    && registration.viewer.equals(viewer)
                    && registration.targetId.equals(targetId)) {
                return true;
            }
        }
        return false;
    }

    /** Final generation, membership, username, and visibility guard before mutation admission. */
    private static PassiveMatchResult currentPassiveMatch(
            Context context, String viewer, String targetId) {
        long generation;
        String key = passiveKey(viewer, targetId);
        synchronized (PASSIVE_VISIBILITY_LOCK) {
            Long matchedGeneration = PASSIVE_MATCH_GENERATIONS.get(key);
            if (matchedGeneration == null
                    || !hasVisibleRegistrationLocked(viewer, targetId)) {
                return new PassiveMatchResult(true, false);
            }
            generation = matchedGeneration.longValue();
        }
        BlocklistStore.IdMatch match = BlocklistStore.isCurrentIdMatch(
                context, targetId, generation);
        if (!match.storeValid) {
            synchronized (PASSIVE_VISIBILITY_LOCK) {
                PASSIVE_MATCH_GENERATIONS.remove(key);
            }
            latchPassiveStorePause(context, viewer, match.generation);
            return new PassiveMatchResult(false, false);
        }
        boolean current;
        synchronized (PASSIVE_VISIBILITY_LOCK) {
            current = match.matched
                    && hasVisibleRegistrationLocked(viewer, targetId)
                    && visibleUsernameMatchesStoredLocked(viewer, targetId, match.username);
            if (!current) {
                PASSIVE_MATCH_GENERATIONS.remove(key);
            }
        }
        return new PassiveMatchResult(true, current);
    }

    private static boolean visibleUsernameMatchesStored(
            String viewer, String targetId, String storedUsername) {
        synchronized (PASSIVE_VISIBILITY_LOCK) {
            return visibleUsernameMatchesStoredLocked(viewer, targetId, storedUsername);
        }
    }

    private static boolean visibleUsernameMatchesStoredLocked(
            String viewer, String targetId, String storedUsername) {
        String stored = BlocklistStore.normalizedUsername(storedUsername);
        if (stored.length() == 0) {
            return false;
        }
        boolean found = false;
        for (PassiveRegistration registration : PASSIVE_REGISTRATIONS.values()) {
            if (!registration.visible
                    || !registration.viewer.equals(viewer)
                    || !registration.targetId.equals(targetId)) {
                continue;
            }
            String visible = BlocklistStore.normalizedUsername(registration.username);
            if (visible.length() == 0 || !stored.equals(visible)) {
                return false;
            }
            found = true;
        }
        return found;
    }

    private static void latchPassiveStorePause(
            Context context, String viewer, long observedGeneration) {
        synchronized (PASSIVE_ADMISSION_LOCK) {
            BlocklistStore.Snapshot current = BlocklistStore.snapshot(context);
            if (observedGeneration > 0L
                    && current.valid
                    && current.generation > observedGeneration) {
                return;
            }
            synchronized (PASSIVE_STORE_PAUSE_LOCK) {
                passiveStorePaused = true;
                passiveStorePauseGeneration = Math.max(
                        passiveStorePauseGeneration, Math.max(0L, observedGeneration));
            }
            synchronized (PASSIVE_VISIBILITY_LOCK) {
                PASSIVE_LOOKUP_QUEUE.clear();
                PASSIVE_LOOKUP_QUEUED.clear();
                PASSIVE_MATCH_GENERATIONS.clear();
            }
        }
        String status = "Indexed-list storage is invalid or unavailable; passive blocking is paused.";
        setStatus(context, viewer, status);
        ModStateStore.recordRuntimeState(
                context, viewer, "passive_store_invalid", status, true);
    }

    private static boolean isPassiveStorePaused() {
        synchronized (PASSIVE_STORE_PAUSE_LOCK) {
            return passiveStorePaused;
        }
    }

    private static boolean clearPassiveStorePauseAfterVerifiedGeneration(long generation) {
        synchronized (PASSIVE_STORE_PAUSE_LOCK) {
            if (!passiveStorePaused || generation <= passiveStorePauseGeneration) {
                return !passiveStorePaused;
            }
            passiveStorePaused = false;
            passiveStorePauseGeneration = 0L;
            return true;
        }
    }

    private static void clearPassiveVisibility() {
        synchronized (PASSIVE_VISIBILITY_LOCK) {
            PASSIVE_REGISTRATIONS.clear();
            PASSIVE_LOOKUP_QUEUE.clear();
            PASSIVE_LOOKUP_QUEUED.clear();
            PASSIVE_MATCH_GENERATIONS.clear();
        }
    }

    /** Preserves remembered row tokens but requires fresh foreground geometry before admission. */
    private static void pausePassiveVisibility() {
        synchronized (PASSIVE_VISIBILITY_LOCK) {
            for (PassiveRegistration registration : PASSIVE_REGISTRATIONS.values()) {
                registration.visible = false;
            }
            PASSIVE_LOOKUP_QUEUE.clear();
            PASSIVE_LOOKUP_QUEUED.clear();
            PASSIVE_MATCH_GENERATIONS.clear();
        }
    }

    private static String passiveKey(String viewer, String targetId) {
        if (!isDecimalId(viewer) || viewer.length() > 24
                || !isDecimalId(targetId) || targetId.length() > 24) {
            return null;
        }
        return viewer + "\n" + targetId;
    }

    private static String passiveViewerFromKey(String key) {
        if (key == null) {
            return null;
        }
        int split = key.indexOf('\n');
        if (split <= 0) {
            return null;
        }
        String viewer = key.substring(0, split);
        return isDecimalId(viewer) && viewer.length() <= 24 ? viewer : null;
    }

    private static String passiveTargetFromKey(String key, String viewer) {
        if (key == null || viewer == null || !key.startsWith(viewer + "\n")) {
            return null;
        }
        String targetId = key.substring(viewer.length() + 1);
        return isDecimalId(targetId) && targetId.length() <= 24 ? targetId : null;
    }

    private static boolean isUsableBlocklistSnapshot(
            BlocklistStore.Snapshot snapshot, long now) {
        return snapshot != null
                && snapshot.valid
                && snapshot.fetchedAtMs > 0L
                && snapshot.verifiedUpdatedAtMs > 0L
                && now >= snapshot.fetchedAtMs
                && now - snapshot.fetchedAtMs <= CACHE_MAX_AGE_MS
                && snapshot.verifiedUpdatedAtMs >= now - SIGNED_LIST_MAX_AGE_MS
                && snapshot.verifiedUpdatedAtMs <= now + 24L * 60L * 60L * 1000L;
    }

    private static long millisUntilNextListRefresh(Context context) {
        long now = System.currentTimeMillis();
        DeadlineState deadline = readListRefreshDeadline(context, now);
        if (!deadline.valid) {
            return FETCH_INTERVAL_MS;
        }
        return deadline.value <= now
                ? 1000L : Math.max(1000L, deadline.value - now);
    }

    static String cleanSignedUsername(String value) {
        if (value == null) {
            return "";
        }
        String username = value.trim();
        while (username.startsWith("@")) {
            username = username.substring(1);
        }
        if (username.length() == 0 || username.length() > 64) {
            return "";
        }
        for (int i = 0; i < username.length(); i++) {
            char c = username.charAt(i);
            boolean allowed = c >= 'a' && c <= 'z'
                    || c >= 'A' && c <= 'Z'
                    || c >= '0' && c <= '9'
                    || c == '_' || c == '.';
            if (!allowed) {
                return "";
            }
        }
        return username;
    }

    private static final class BlockRun implements BridgeCallback {
        private final Activity activity;
        private final Object userSession;
        private final String viewer;
        private final String targetId;
        private final boolean forceRefresh;
        private final long schedulerToken;
        private final AtomicBoolean finished = new AtomicBoolean(false);

        private int token;
        private boolean waiting;
        private boolean started;

        BlockRun(
                Activity activity,
                Object userSession,
                String viewer,
                String targetId,
                boolean forceRefresh,
                long schedulerToken) {
            this.activity = activity;
            this.userSession = userSession;
            this.viewer = viewer;
            this.targetId = targetId;
            this.forceRefresh = forceRefresh;
            this.schedulerToken = schedulerToken;
        }

        void begin() {
            if (!isMainLooperThread()) {
                finish("Passive admission left the main thread; automatic work remains paused.");
                return;
            }
            if (finished.get() || !isSchedulerOwner(schedulerToken)) {
                finished.set(true);
                return;
            }
            if (!isCurrentForeground()) {
                finishForForegroundChange(
                        "List verified; blocking moved to the current Threads screen.",
                        forceRefresh);
                return;
            }
            if (ModStateStore.nextQueued(activity, viewer) != null) {
                finishAndResume(
                        "Passive blocking paused for a user-requested inline Block.", 0L);
                return;
            }
            if (!BlockLimitsStore.isValid(activity)) {
                finish("Stored passive delay needs review; automatic work remains fail-closed.");
                scheduleManualDrain(SAFETY_REVIEW_WAKE_MS);
                return;
            }
            long paceWait = millisUntilPassivePaceAllowed(activity, viewer);
            if (paceWait > 0L) {
                setStatus(activity, viewer, paceWait == SAFETY_REVIEW_WAKE_MS
                        ? "Local pacing state needs review; blocking remains fail-closed."
                        : "Waiting for the configured delay before the next passive block.");
                finishAndResume(
                        paceWait == SAFETY_REVIEW_WAKE_MS
                                ? "Local pacing state needs review; blocking remains fail-closed."
                                : "Waiting for the configured delay before the next passive block.",
                        paceWait);
                return;
            }

            Set<String> done = doneIds(activity, viewer);
            if (done == null) {
                finish("Completed-target state needs review; automatic work remains paused.");
                return;
            }
            ModStateStore.CompletionReviewState review =
                    ModStateStore.completionReviewState(activity, viewer);
            if (!review.valid || review.full || isLocalCompletionReviewPaused(viewer)) {
                finish("Completion-review state needs attention; automatic work remains paused.");
                return;
            }
            if (targetId == null || targetId.equals(viewer) || done.contains(targetId)
                    || review.targets.contains(targetId)) {
                finishAndResume("The selected visible match is no longer eligible.", 0L);
                return;
            }
            waiting = true;
            started = false;
            final int watchdogToken;
            synchronized (PASSIVE_ADMISSION_LOCK) {
                // List replacement uses this same lock, so generation membership stays current
                // through durable running-state persistence, passive pacing reservation,
                // and native bridge dispatch.
                if (!isCurrentForeground()) {
                    waiting = false;
                    finishForForegroundChange(
                            "Paused when the Threads screen changed; resuming safely.", false);
                    return;
                }
                if (ModStateStore.nextQueued(activity, viewer) != null) {
                    waiting = false;
                    finishAndResume(
                            "Passive blocking paused for a user-requested inline Block.", 0L);
                    return;
                }
                if (!BlockLimitsStore.isValid(activity)) {
                    waiting = false;
                    finish("Stored passive delay needs review; automatic work remains fail-closed.");
                    scheduleManualDrain(SAFETY_REVIEW_WAKE_MS);
                    return;
                }
                Set<String> currentDone = doneIds(activity, viewer);
                ModStateStore.CompletionReviewState currentReview =
                        ModStateStore.completionReviewState(activity, viewer);
                if (currentDone == null || !currentReview.valid || currentReview.full
                        || isLocalCompletionReviewPaused(viewer)) {
                    waiting = false;
                    finish("Completion-review state needs attention; automatic work remains paused.");
                    return;
                }
                if (targetId.equals(viewer) || currentDone.contains(targetId)
                        || currentReview.targets.contains(targetId)) {
                    waiting = false;
                    finishAndResume("The selected visible match is no longer eligible.", 0L);
                    return;
                }
                PassiveMatchResult initialMatch =
                        currentPassiveMatch(activity, viewer, targetId);
                if (!initialMatch.storeValid) {
                    waiting = false;
                    finish("Indexed-list storage needs a verified replacement; passive blocking is paused.");
                    return;
                }
                if (!initialMatch.matched) {
                    waiting = false;
                    finishAndResume("The selected profile is no longer a current visible match.", 0L);
                    return;
                }

                // This exact-SHA bridge preflight resolves the same direct-ID model and reads
                // Threads' native blocked predicate without dispatching a mutation. It must
                // finish before running-state persistence or passive delay reservation, so a
                // profile that Threads already reports blocked consumes no configured delay.
                String preflightStage;
                try {
                    preflightStage = ThreadsBlockBridge.passivePreflight(
                            userSession, targetId);
                } catch (Throwable ignored) {
                    preflightStage = "bridge_dispatch_exception";
                }

                // Preflight can touch private host state. Revalidate every mutable authority
                // that can change while it runs before interpreting its result or reserving work.
                if (!isCurrentForeground()) {
                    waiting = false;
                    finishForForegroundChange(
                            "Paused when the Threads screen changed; resuming safely.", false);
                    return;
                }
                if (ModStateStore.nextQueued(activity, viewer) != null) {
                    waiting = false;
                    finishAndResume(
                            "Passive blocking paused for a user-requested inline Block.", 0L);
                    return;
                }
                PassiveMatchResult postPreflightMatch =
                        currentPassiveMatch(activity, viewer, targetId);
                if (!postPreflightMatch.storeValid) {
                    waiting = false;
                    finish("Indexed-list storage needs a verified replacement; passive blocking is paused.");
                    return;
                }
                if (!postPreflightMatch.matched) {
                    waiting = false;
                    finishAndResume("The selected profile is no longer a current visible match.", 0L);
                    return;
                }
                if ("already_blocked_success".equals(preflightStage)) {
                    handleAlreadyBlockedBeforeReservation();
                    return;
                }
                if (preflightStage != null) {
                    handlePreflightFailure(preflightStage);
                    return;
                }

                if (!BlockLimitsStore.isValid(activity)) {
                    waiting = false;
                    finish("Stored passive delay needs review; automatic work remains fail-closed.");
                    scheduleManualDrain(SAFETY_REVIEW_WAKE_MS);
                    return;
                }
                currentDone = doneIds(activity, viewer);
                currentReview = ModStateStore.completionReviewState(activity, viewer);
                if (currentDone == null || !currentReview.valid || currentReview.full
                        || isLocalCompletionReviewPaused(viewer)) {
                    waiting = false;
                    finish("Completion-review state needs attention; automatic work remains paused.");
                    return;
                }
                if (targetId.equals(viewer) || currentDone.contains(targetId)
                        || currentReview.targets.contains(targetId)) {
                    waiting = false;
                    finishAndResume("The selected visible match is no longer eligible.", 0L);
                    return;
                }
                PassiveMatchResult finalMatch =
                        currentPassiveMatch(activity, viewer, targetId);
                if (!finalMatch.storeValid) {
                    waiting = false;
                    finish("Indexed-list storage needs a verified replacement; passive blocking is paused.");
                    return;
                }
                if (!finalMatch.matched) {
                    waiting = false;
                    finishAndResume("The selected profile is no longer a current visible match.", 0L);
                    return;
                }
                long currentPaceWait = millisUntilPassivePaceAllowed(activity, viewer);
                if (currentPaceWait > 0L) {
                    waiting = false;
                    finishAndResume(
                            currentPaceWait == SAFETY_REVIEW_WAKE_MS
                                    ? "Local pacing state needs review; blocking remains fail-closed."
                                    : "Waiting for the configured delay before the next passive block.",
                            currentPaceWait);
                    return;
                }
                PassiveAuthority beforeRunning =
                        currentPassiveAuthority(false, false);
                if (!beforeRunning.allowed) {
                    stopForAuthorityFailure(beforeRunning, false);
                    return;
                }
                if (!ModStateStore.markPassiveRunning(activity, viewer, targetId)) {
                    waiting = false;
                    boolean backoffPersisted = persistRetryDeadline(activity, viewer);
                    BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                            "queue_start_persistence", true, false, false,
                            backoffPersisted);
                    ModStateStore.recordAutomaticFailure(
                            activity, viewer, targetId, diagnostic);
                    ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
                    Log.w(TAG, diagnostic.logLine());
                    finish(diagnostic.status());
                    scheduleManualDrain(FAILURE_BACKOFF_MS + 1000L);
                    return;
                }
                PassiveAuthority beforeReservation =
                        currentPassiveAuthority(true, false);
                if (!beforeReservation.allowed) {
                    stopForAuthorityFailure(beforeReservation, true);
                    return;
                }
                if (!reserveAttempt(activity, viewer, true)) {
                    waiting = false;
                    boolean runningCleared = ModStateStore.clearPassiveRunning(
                            activity, viewer, targetId);
                    if (!runningCleared) {
                        boolean reviewSaved = quarantineCompletionReview(
                                activity, viewer, targetId);
                        BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                                "completion_persistence", true, false, false, reviewSaved);
                        ModStateStore.recordAutomaticFailure(
                                activity, viewer, targetId, diagnostic);
                        ModStateStore.recordFailureDiagnostic(
                                activity, viewer, diagnostic);
                        Log.w(TAG, diagnostic.logLine());
                        finish(diagnostic.status());
                        return;
                    }
                    boolean backoffPersisted = persistRetryDeadline(activity, viewer);
                    BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                            "attempt_reservation", true, false, false,
                            backoffPersisted);
                    ModStateStore.recordAutomaticFailure(
                            activity, viewer, targetId, diagnostic);
                    ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
                    Log.w(TAG, diagnostic.logLine());
                    finish(diagnostic.status());
                    scheduleManualDrain(FAILURE_BACKOFF_MS + 1000L);
                    return;
                }
                PassiveAuthority beforeDispatch =
                        currentPassiveAuthority(true, true);
                if (!beforeDispatch.allowed) {
                    stopForAuthorityFailure(beforeDispatch, true);
                    return;
                }
                if (!markSchedulerMutationInFlight(schedulerToken, true)) {
                    waiting = false;
                    if (!ModStateStore.clearPassiveRunning(activity, viewer, targetId)) {
                        quarantineCompletionReview(activity, viewer, targetId);
                    }
                    finishForForegroundChange(
                            "Blocking moved to the current Threads screen.", forceRefresh);
                    return;
                }
                setStatus(activity, viewer, "Blocking one current visible indexed match...");
                watchdogToken = ++token;
                try {
                    ThreadsBlockBridge.block(activity, userSession, targetId, this);
                } catch (Throwable error) {
                    handleFailure(targetId, "bridge_exception");
                    return;
                }
            }
            boolean watchdogPosted = MAIN.postDelayed(new Runnable() {
                @Override
                public void run() {
                    if (!finished.get() && waiting && token == watchdogToken) {
                        handleUncertainMutation(targetId);
                    }
                }
            }, WATCHDOG_MS);
            if (!watchdogPosted) {
                handleUncertainMutation(targetId);
            }
        }

        private PassiveAuthority currentPassiveAuthority(
                boolean runningPersisted, boolean reservationPersisted) {
            if (!isMainLooperThread()) {
                return PassiveAuthority.pause(
                        "Passive admission left the main thread; automatic work remains paused.");
            }
            if (!isCurrentForeground()) {
                return PassiveAuthority.foregroundChanged(
                        "Paused when the Threads screen changed; resuming safely.");
            }
            if (isPassiveStorePaused()) {
                return PassiveAuthority.pause(
                        "Indexed-list storage needs a verified replacement; passive blocking is paused.");
            }
            if (ModStateStore.nextQueued(activity, viewer) != null) {
                return PassiveAuthority.resume(
                        "Passive blocking paused for a user-requested inline Block.", 0L);
            }
            if (!BlockLimitsStore.isValid(activity)) {
                return PassiveAuthority.pause(
                        "Stored passive delay needs review; automatic work remains fail-closed.");
            }
            Set<String> currentDone = doneIds(activity, viewer);
            ModStateStore.CompletionReviewState currentReview =
                    ModStateStore.completionReviewState(activity, viewer);
            if (currentDone == null || !currentReview.valid || currentReview.full
                    || isLocalCompletionReviewPaused(viewer)) {
                return PassiveAuthority.pause(
                        "Completion-review state needs attention; automatic work remains paused.");
            }
            if (targetId == null || targetId.equals(viewer)
                    || currentDone.contains(targetId)
                    || currentReview.targets.contains(targetId)) {
                return PassiveAuthority.resume(
                        "The selected visible match is no longer eligible.", 0L);
            }
            if (!runningPersisted
                    && !ModStateStore.isPassiveRunningClear(activity, viewer)) {
                return PassiveAuthority.pause(
                        "Interrupted passive state needs review; automatic blocking remains paused.");
            }
            PassiveMatchResult currentMatch =
                    currentPassiveMatch(activity, viewer, targetId);
            if (!currentMatch.storeValid) {
                return PassiveAuthority.pause(
                        "Indexed-list storage needs a verified replacement; passive blocking is paused.");
            }
            if (!currentMatch.matched) {
                return PassiveAuthority.resume(
                        "The selected profile is no longer a current visible match.", 0L);
            }
            if (!reservationPersisted) {
                long paceWait = millisUntilPassivePaceAllowed(activity, viewer);
                if (paceWait > 0L) {
                    return PassiveAuthority.resume(
                            paceWait == SAFETY_REVIEW_WAKE_MS
                                    ? "Local pacing state needs review; blocking remains fail-closed."
                                    : "Waiting for the configured delay before the next passive block.",
                            paceWait);
                }
            }
            return PassiveAuthority.allowed();
        }

        private void stopForAuthorityFailure(
                PassiveAuthority authority,
                boolean runningPersisted) {
            waiting = false;
            if (runningPersisted
                    && !ModStateStore.clearPassiveRunning(activity, viewer, targetId)) {
                boolean reviewSaved = quarantineCompletionReview(
                        activity, viewer, targetId);
                BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                        "completion_persistence", true, false, false, reviewSaved);
                try {
                    ModStateStore.recordAutomaticFailure(
                            activity, viewer, targetId, diagnostic);
                    ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
                    Log.w(TAG, diagnostic.logLine());
                } finally {
                    finish(diagnostic.status());
                }
                return;
            }
            if (authority.foregroundChanged) {
                finishForForegroundChange(authority.status, forceRefresh);
            } else if (authority.resume) {
                finishAndResume(authority.status, authority.delayMs);
            } else {
                finish(authority.status);
            }
        }

        /** Native state says this target is already blocked; reserve no passive delay. */
        private void handleAlreadyBlockedBeforeReservation() {
            waiting = false;
            boolean completionSaved = false;
            try {
                completionSaved = markDone(activity, viewer, targetId);
            } catch (Throwable ignored) {
                // A thrown save follows the same bounded completion-review quarantine path.
            }
            if (!completionSaved) {
                boolean reviewSaved = quarantineCompletionReview(
                        activity, viewer, targetId);
                BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                        "completion_persistence", true, false, false, reviewSaved);
                try {
                    ModStateStore.recordAutomaticFailure(
                            activity, viewer, targetId, diagnostic);
                } catch (Throwable ignored) {
                    // Quarantine is authoritative when optional history cannot save.
                }
                try {
                    ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
                } catch (Throwable ignored) {
                    // Continue to unconditional scheduler release.
                }
                try {
                    Log.w(TAG, diagnostic.logLine());
                } catch (Throwable ignored) {
                    // Logging is best effort only.
                }
                finish(diagnostic.status());
                return;
            }
            try {
                clearRetryDeadline(activity, viewer);
            } catch (Throwable ignored) {
                // The completed-ID record remains authoritative for future selection.
            }
            finishAndResume(
                    "Skipped one visible profile that Threads already reports blocked.", 0L);
        }

        /** A callback-free preflight failure is retryable, but it never reserves an attempt. */
        private void handlePreflightFailure(String stage) {
            waiting = false;
            boolean backoffPersisted = false;
            try {
                backoffPersisted = persistRetryDeadline(activity, viewer);
            } catch (Throwable ignored) {
                // The closed diagnostic records that durable retry state was unavailable.
            }
            BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                    stage, true, false, false, backoffPersisted);
            try {
                ModStateStore.recordAutomaticFailure(
                        activity, viewer, targetId, diagnostic);
            } catch (Throwable ignored) {
                // The process-local deadline still prevents an immediate retry.
            }
            try {
                ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
            } catch (Throwable ignored) {
                // Continue to unconditional scheduler release.
            }
            try {
                Log.w(TAG, diagnostic.logLine());
            } catch (Throwable ignored) {
                // Logging is best effort only.
            }
            finish(diagnostic.status());
            scheduleManualDrain(FAILURE_BACKOFF_MS + 1000L);
        }

        @Override
        public void onBridgeStarted(final String targetId) {
            if (!isCurrent(targetId)) {
                return;
            }
            started = true;
            setStatus(activity, viewer, "Blocking one current visible indexed match...");
        }

        @Override
        public void onBridgeSuccess(final String targetId) {
            if (!isCurrent(targetId)) {
                return;
            }
            boolean completionSaved = false;
            try {
                completionSaved = markDone(activity, viewer, targetId)
                        && ModStateStore.clearPassiveRunning(activity, viewer, targetId);
            } catch (Throwable ignored) {
                // A thrown local save follows the same confirmed-success quarantine path.
            }
            if (!completionSaved) {
                handleCompletionPersistence(targetId);
                return;
            }
            markSchedulerMutationInFlight(schedulerToken, false);
            try {
                ModStateStore.recordAutomaticBlocked(activity, viewer, targetId);
            } catch (Throwable ignored) {
                // Completion ownership is already durable; history is best effort.
            }
            waiting = false;
            try {
                clearRetryDeadline(activity, viewer);
            } catch (Throwable ignored) {
                // A stale pause cannot repeat this completed target.
            }
            try {
                if (!isCurrentForeground()) {
                    finishForForegroundChange(
                            "Block completed; continuing on the current Threads screen.",
                            false);
                    return;
                }
                long delay = millisUntilPassivePaceAllowed(activity, viewer);
                finishAndResume(
                        "Completed one passive block; the next target will be selected by a "
                                + "fresh scheduler drain.",
                        delay);
            } catch (Throwable ignored) {
                finish("Block completed; local scheduler state needs review.");
            }
        }

        @Override
        public void onBridgeFailure(final String targetId, final String stage) {
            handleFailure(targetId, stage);
        }

        private void handleFailure(String targetId, String stage) {
            if (!isCurrent(targetId)) {
                return;
            }
            if ("completion_persistence".equals(stage)) {
                handleCompletionPersistence(targetId);
                return;
            }
            if ("callback_timeout".equals(stage)) {
                handleUncertainMutation(targetId);
                return;
            }
            waiting = false;
            markSchedulerMutationInFlight(schedulerToken, false);
            if (!ModStateStore.clearPassiveRunning(activity, viewer, targetId)) {
                boolean reviewSaved = quarantineCompletionReview(
                        activity, viewer, targetId);
                BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                        "completion_persistence", true, false, started, reviewSaved);
                try {
                    ModStateStore.recordAutomaticFailure(
                            activity, viewer, targetId, diagnostic);
                    ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
                    Log.w(TAG, diagnostic.logLine());
                } finally {
                    finish(diagnostic.status());
                }
                return;
            }
            boolean backoffPersisted = persistRetryDeadline(activity, viewer);
            BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                    stage, true, false, started, backoffPersisted);
            ModStateStore.recordAutomaticFailure(
                    activity, viewer, targetId, diagnostic);
            ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
            Log.w(TAG, diagnostic.logLine());
            finish(diagnostic.status());
            scheduleManualDrain(FAILURE_BACKOFF_MS + 1000L);
        }

        /** A dispatched mutation without a terminal callback is never retried automatically. */
        private void handleUncertainMutation(String targetId) {
            if (!isCurrent(targetId)) {
                return;
            }
            waiting = false;
            markSchedulerMutationInFlight(schedulerToken, false);
            boolean reviewSaved = quarantineCompletionReview(activity, viewer, targetId);
            if (reviewSaved) {
                ModStateStore.clearPassiveRunning(activity, viewer, targetId);
            }
            BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                    "callback_timeout", true, false, started, reviewSaved);
            try {
                ModStateStore.recordAutomaticFailure(
                        activity, viewer, targetId, diagnostic);
            } catch (Throwable ignored) {
                // Quarantine is authoritative when optional history cannot save.
            }
            try {
                ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
            } catch (Throwable ignored) {
                // Continue to unconditional scheduler release.
            }
            try {
                Log.w(TAG, diagnostic.logLine());
            } catch (Throwable ignored) {
                // Logging is best effort only.
            }
            finish(diagnostic.status());
        }

        /** Native success is terminal; quarantine instead of retrying the mutation. */
        private void handleCompletionPersistence(String targetId) {
            if (!isCurrent(targetId)) {
                return;
            }
            waiting = false;
            markSchedulerMutationInFlight(schedulerToken, false);
            boolean reviewSaved = quarantineCompletionReview(activity, viewer, targetId);
            if (reviewSaved) {
                ModStateStore.clearPassiveRunning(activity, viewer, targetId);
            }
            BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                    "completion_persistence", true, false, true, reviewSaved);
            try {
                ModStateStore.recordAutomaticFailure(
                        activity, viewer, targetId, diagnostic);
            } catch (Throwable ignored) {
                // Quarantine is authoritative when optional history cannot save.
            }
            try {
                ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
            } catch (Throwable ignored) {
                // Continue to unconditional scheduler release.
            }
            try {
                Log.w(TAG, diagnostic.logLine());
            } catch (Throwable ignored) {
                // Logging is best effort only.
            }
            finish(diagnostic.status());
        }

        private boolean isCurrent(String targetId) {
            return !finished.get()
                    && isSchedulerOwner(schedulerToken)
                    && waiting
                    && this.targetId.equals(targetId);
        }

        private boolean isCurrentForeground() {
            if (!foreground || !isEnabled(activity)) {
                return false;
            }
            Activity active = currentActivity.get();
            if (active != activity || activity.isFinishing() || activity.isDestroyed()) {
                return false;
            }
            String liveViewer = viewerId(userSession);
            return viewer.equals(liveViewer) && viewer.equals(currentViewer);
        }

        private void finish(String status) {
            if (!finished.compareAndSet(false, true)) {
                return;
            }
            waiting = false;
            try {
                setStatus(activity, viewer, status);
            } catch (Throwable ignored) {
                // Status is best effort; never crash after a local-only quarantine.
            } finally {
                releaseSchedulerAndContinue(
                        schedulerToken, activity, viewer, 0L, false);
            }
        }

        /** Releases this one-target owner and lets a new manual-first drain select again. */
        private void finishAndResume(String status, long delayMs) {
            if (!finished.compareAndSet(false, true)) {
                return;
            }
            waiting = false;
            try {
                setStatus(activity, viewer, status);
            } catch (Throwable ignored) {
                // Status is best effort; fresh selection still requires a new scheduler owner.
            } finally {
                releaseSchedulerAndContinue(
                        schedulerToken, activity, viewer,
                        Math.max(0L, delayMs), true);
            }
        }

        private void finishForForegroundChange(String status, boolean preserveForceRefresh) {
            if (!finished.compareAndSet(false, true)) {
                return;
            }
            waiting = false;
            if (preserveForceRefresh) {
                requestForceRefresh(viewer);
            }
            try {
                setStatus(activity, viewer, status);
            } catch (Throwable ignored) {
                // Context-change status is best effort; ownership still must release.
            } finally {
                releaseSchedulerAndContinue(
                        schedulerToken, activity, viewer, 0L, true);
            }
        }
    }

    /** Acquires one identity-bound scheduler owner. Token zero means another owner is active. */
    private static long tryAcquireScheduler(
            Activity activity, String viewer, boolean forceRefresh) {
        if (!isMainLooperThread() || activity == null
                || !isDecimalId(viewer) || viewer.length() > 24) {
            return 0L;
        }
        synchronized (SCHEDULER_LOCK) {
            if (!RUNNING.compareAndSet(false, true)) {
                return 0L;
            }
            schedulerSequence++;
            if (schedulerSequence == 0L) {
                schedulerSequence++;
            }
            schedulerOwnerToken = schedulerSequence;
            schedulerOwnerViewer = viewer;
            schedulerOwnerActivity = new WeakReference<Activity>(activity);
            schedulerMutationInFlight = false;
            schedulerOwnerForceRefresh = forceRefresh;
            return schedulerOwnerToken;
        }
    }

    private static boolean isSchedulerOwner(long token) {
        synchronized (SCHEDULER_LOCK) {
            return token != 0L && RUNNING.get() && schedulerOwnerToken == token;
        }
    }

    private static boolean markSchedulerMutationInFlight(long token, boolean inFlight) {
        synchronized (SCHEDULER_LOCK) {
            if (token == 0L || !RUNNING.get() || schedulerOwnerToken != token) {
                return false;
            }
            schedulerMutationInFlight = inFlight;
            return true;
        }
    }

    /**
     * Account/activity replacement abandons only passive fetch/pace ownership. An authenticated
     * mutation keeps the global slot until its callback/watchdog records a terminal local state.
     */
    private static void releasePassiveSchedulerForContextChange(
            Activity newActivity, String newViewer) {
        boolean released = false;
        boolean preserveForceRefresh = false;
        String releasedViewer = "";
        synchronized (SCHEDULER_LOCK) {
            if (!RUNNING.get() || schedulerOwnerToken == 0L) {
                return;
            }
            Activity ownerActivity = schedulerOwnerActivity.get();
            boolean sameContext = ownerActivity == newActivity
                    && newViewer != null && newViewer.equals(schedulerOwnerViewer);
            if (!sameContext && !schedulerMutationInFlight) {
                preserveForceRefresh = schedulerOwnerForceRefresh;
                releasedViewer = schedulerOwnerViewer;
                schedulerOwnerToken = 0L;
                schedulerOwnerViewer = "";
                schedulerOwnerActivity = new WeakReference<Activity>(null);
                schedulerOwnerForceRefresh = false;
                RUNNING.set(false);
                released = true;
            }
        }
        if (preserveForceRefresh) {
            if (!requestForceRefresh(releasedViewer)) {
                setStatus(newActivity, releasedViewer,
                        "Forced refresh could not be preserved because the bounded viewer queue "
                                + "is full; no other viewer request was removed.");
            }
        }
        if (released) {
            scheduleManualDrain(0L);
        }
    }

    private static void scheduleManualDrain(long delayMs) {
        boolean posted = MAIN.postDelayed(new Runnable() {
            @Override
            public void run() {
                drainManualQueue();
            }
        }, Math.max(0L, delayMs));
        if (!posted) {
            Activity activity = getForegroundActivity();
            String viewer = getCurrentViewer();
            if (activity != null && isDecimalId(viewer) && viewer.length() <= 24) {
                try {
                    setStatus(activity, viewer,
                            "Scheduler wake was rejected; reopen Threads to resume queued work.");
                    ModStateStore.recordRuntimeState(
                            activity, viewer, "scheduler_wake_rejected",
                            "Queued work is paused until Threads resumes in the foreground.", true);
                } catch (Throwable ignored) {
                    // Queued state remains durable and the next foreground resume retries it.
                }
            }
        }
    }

    /**
     * Releases the single-flight scheduler and wakes it only when durable work remains.
     * A verified empty list is terminal for the current sync, while transient failures
     * and manual completions may immediately resume enabled passive work.
     */
    private static void releaseSchedulerAndContinue(
            long schedulerToken,
            Activity activity,
            String viewer,
            long delayMs,
            boolean resumeAuto) {
        synchronized (SCHEDULER_LOCK) {
            if (schedulerOwnerToken != schedulerToken || schedulerToken == 0L) {
                return;
            }
            schedulerOwnerToken = 0L;
            schedulerOwnerViewer = "";
            schedulerOwnerActivity = new WeakReference<Activity>(null);
            schedulerMutationInFlight = false;
            schedulerOwnerForceRefresh = false;
            RUNNING.set(false);
        }
        if (!isDecimalId(viewer) || viewer.length() > 24) {
            return;
        }
        Activity host = getForegroundActivity();
        String liveViewer = getCurrentViewer();
        Object liveSession = currentSession;
        if (host == null || liveViewer == null || liveSession == null
                || !liveViewer.equals(viewerId(liveSession))) {
            return;
        }
        if (!viewer.equals(liveViewer) || host != activity) {
            scheduleManualDrain(0L);
            return;
        }
        boolean manualPending = ModStateStore.nextQueued(host, viewer) != null;
        if (manualPending || (resumeAuto && isEnabled(host))) {
            scheduleManualDrain(delayMs);
        }
    }

    private static void drainManualQueue() {
        if (!isMainLooperThread()) {
            return;
        }
        Activity activity = getForegroundActivity();
        Object session = currentSession;
        String viewer = getCurrentViewer();
        if (activity == null || session == null || viewer == null
                || !viewer.equals(viewerId(session))) {
            return;
        }
        ModStateStore.QueueItem item = ModStateStore.nextQueued(activity, viewer);
        if (item == null) {
            if (isEnabled(activity)) {
                start(activity, session, viewer, false);
            }
            return;
        }
        SharedPreferences p = prefs(activity);
        long now = System.currentTimeMillis();
        DeadlineState retry = readRetryDeadline(p, viewer, now);
        if (!retry.valid) {
            setStatus(activity, viewer,
                    "Local failure-pause state needs review; inline Block remains queued.");
            ModStateStore.recordRuntimeState(
                    activity, viewer, "manual_waiting_safety_review",
                    "A manual block is waiting because local failure-pause state is invalid.",
                    true);
            scheduleManualDrain(SAFETY_REVIEW_WAKE_MS);
            return;
        }
        if (retry.value > now) {
            long retryAt = retry.value;
            setStatus(activity, viewer,
                    "Inline Block is queued behind the two-minute failure pause.");
            ModStateStore.recordRuntimeState(
                    activity, viewer, "manual_waiting_backoff",
                    "A manual block is waiting for the failure pause.", false);
            scheduleManualDrain(retryAt - now + 1000L);
            return;
        }
        long schedulerToken = tryAcquireScheduler(activity, viewer, false);
        if (schedulerToken == 0L) {
            return;
        }
        if (!ModStateStore.markManualStarted(activity, viewer, item.targetId)) {
            boolean backoffPersisted = persistRetryDeadline(activity, viewer);
            BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                    "queue_start_persistence", false, false, false, backoffPersisted);
            ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
            setStatus(activity, viewer, diagnostic.status());
            Log.w(TAG, diagnostic.logLine());
            releaseSchedulerAndContinue(
                    schedulerToken, activity, viewer,
                    FAILURE_BACKOFF_MS + 1000L, true);
            dispatchManualFailure(viewer, item.targetId, diagnostic.stage());
            return;
        }
        if (!reserveAttempt(activity, viewer, false)) {
            boolean backoffPersisted = persistRetryDeadline(activity, viewer);
            BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                    "attempt_reservation", false, false, false, backoffPersisted);
            ModStateStore.markManualFailed(
                    activity, viewer, item.targetId, diagnostic);
            ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
            setStatus(activity, viewer, diagnostic.status());
            Log.w(TAG, diagnostic.logLine());
            releaseSchedulerAndContinue(
                    schedulerToken, activity, viewer,
                    FAILURE_BACKOFF_MS + 1000L, true);
            dispatchManualFailure(viewer, item.targetId, diagnostic.stage());
            return;
        }
        Object resolvedAuthorModel = takeResolvedAuthorModel(
                viewer, item.targetId, session);
        new ManualBlockRun(
                activity, session, viewer, item.targetId,
                resolvedAuthorModel, schedulerToken).begin();
    }

    private static final class ManualBlockRun implements BridgeCallback {
        private final Activity activity;
        private final Object userSession;
        private final String viewer;
        private final String targetId;
        private final Object resolvedAuthorModel;
        private final long schedulerToken;
        private final AtomicBoolean finished = new AtomicBoolean(false);
        private boolean started;

        ManualBlockRun(
                Activity activity,
                Object userSession,
                String viewer,
                String targetId,
                Object resolvedAuthorModel,
                long schedulerToken) {
            this.activity = activity;
            this.userSession = userSession;
            this.viewer = viewer;
            this.targetId = targetId;
            this.resolvedAuthorModel = resolvedAuthorModel;
            this.schedulerToken = schedulerToken;
        }

        void begin() {
            if (!isMainLooperThread()) {
                fail("scheduler_handoff");
                return;
            }
            if (!isCurrentForeground()) {
                fail("foreground_changed");
                return;
            }
            if (!markSchedulerMutationInFlight(schedulerToken, true)) {
                fail("scheduler_handoff");
                return;
            }
            try {
                if (resolvedAuthorModel == null) {
                    ThreadsBlockBridge.block(activity, userSession, targetId, this);
                } else {
                    ThreadsBlockBridge.blockResolved(
                            activity, userSession, resolvedAuthorModel, targetId, this);
                }
            } catch (Throwable ignored) {
                fail("bridge_exception");
                return;
            }
            boolean watchdogPosted = MAIN.postDelayed(new Runnable() {
                @Override
                public void run() {
                    abandonUncertainMutation();
                }
            }, WATCHDOG_MS);
            if (!watchdogPosted) {
                abandonUncertainMutation();
            }
        }

        @Override
        public void onBridgeStarted(final String id) {
            if (!isCurrent(id) || started) {
                return;
            }
            started = true;
            dispatchManualStarted(viewer, targetId);
            setStatus(activity, viewer, "Blocking the user selected inline...");
            ModStateStore.recordRuntimeState(
                    activity, viewer, "manual_in_flight",
                    "A user-requested inline block is in flight.", false);
        }

        @Override
        public void onBridgeSuccess(final String id) {
            if (!isCurrent(id) || !finished.compareAndSet(false, true)) {
                return;
            }
            boolean completionSaved = false;
            try {
                completionSaved = ModStateStore.markManualBlocked(
                        activity, viewer, targetId);
            } catch (Throwable ignored) {
                // A thrown local save follows the same confirmed-success quarantine path.
            }
            if (!completionSaved) {
                handleCompletionPersistenceAfterSuccess();
                return;
            }
            markSchedulerMutationInFlight(schedulerToken, false);
            try {
                try {
                    clearRetryDeadline(activity, viewer);
                } catch (Throwable ignored) {
                    // A stale pause cannot repeat this completed target.
                }
                try {
                    setStatus(activity, viewer,
                            "Inline Block completed after Threads confirmed success.");
                    ModStateStore.recordRuntimeState(
                            activity, viewer, "manual_succeeded",
                            "Threads confirmed the inline block.", false);
                } catch (Throwable ignored) {
                    // Completion ownership is already durable.
                }
                dispatchManualSuccess(viewer, targetId);
            } finally {
                releaseSchedulerAndContinue(
                        schedulerToken, activity, viewer, 0L, true);
            }
        }

        @Override
        public void onBridgeFailure(final String id, final String stage) {
            if (targetId.equals(id)) {
                fail(stage);
            }
        }

        private boolean isCurrent(String id) {
            return !finished.get()
                    && isSchedulerOwner(schedulerToken)
                    && targetId.equals(id);
        }

        private boolean isCurrentForeground() {
            return getForegroundActivity() == activity
                    && viewer.equals(getCurrentViewer())
                    && viewer.equals(viewerId(userSession));
        }

        private void fail(String stage) {
            if ("callback_timeout".equals(stage)) {
                abandonUncertainMutation();
                return;
            }
            if (!finished.compareAndSet(false, true)) {
                return;
            }
            markSchedulerMutationInFlight(schedulerToken, false);
            boolean backoffPersisted = persistRetryDeadline(activity, viewer);
            BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                    stage, false, resolvedAuthorModel != null,
                    started, backoffPersisted);
            ModStateStore.markManualFailed(activity, viewer, targetId, diagnostic);
            ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
            setStatus(activity, viewer, diagnostic.status());
            Log.w(TAG, diagnostic.logLine());
            releaseSchedulerAndContinue(
                    schedulerToken, activity, viewer,
                    FAILURE_BACKOFF_MS + 1000L, true);
            dispatchManualFailure(viewer, targetId, diagnostic.stage());
        }

        /** Keeps an uncertain inline mutation abandoned until the user explicitly retries it. */
        private void abandonUncertainMutation() {
            if (!finished.compareAndSet(false, true)) {
                return;
            }
            markSchedulerMutationInFlight(schedulerToken, false);
            boolean reviewSaved = quarantineCompletionReview(activity, viewer, targetId);
            BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                    "callback_timeout", false, resolvedAuthorModel != null,
                    started, reviewSaved);
            try {
                try {
                    ModStateStore.markManualAbandoned(
                            activity, viewer, targetId, diagnostic.detail());
                } catch (Throwable ignored) {
                    // The quarantine remains authoritative if queue review cannot save.
                }
                try {
                    ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
                    setStatus(activity, viewer, diagnostic.status());
                } catch (Throwable ignored) {
                    // Continue to unconditional scheduler release.
                }
                try {
                    Log.w(TAG, diagnostic.logLine());
                } catch (Throwable ignored) {
                    // Logging is best effort only.
                }
            } finally {
                try {
                    releaseSchedulerAndContinue(
                            schedulerToken, activity, viewer, 0L, false);
                } finally {
                    dispatchManualFailure(viewer, targetId, diagnostic.stage());
                }
            }
        }

        /** Native success is terminal; keep the queue reviewable without automatic retry. */
        private void handleCompletionPersistenceAfterSuccess() {
            markSchedulerMutationInFlight(schedulerToken, false);
            boolean reviewSaved = quarantineCompletionReview(activity, viewer, targetId);
            BlockDiagnostic diagnostic = BlockDiagnostic.forFailure(
                    "completion_persistence", false, resolvedAuthorModel != null,
                    true, reviewSaved);
            try {
                try {
                    ModStateStore.markManualFailed(activity, viewer, targetId, diagnostic);
                } catch (Throwable ignored) {
                    // The quarantine remains authoritative if queue review cannot save.
                }
                try {
                    ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic);
                    setStatus(activity, viewer, diagnostic.status());
                } catch (Throwable ignored) {
                    // Continue to unconditional scheduler release.
                }
                try {
                    Log.w(TAG, diagnostic.logLine());
                } catch (Throwable ignored) {
                    // Logging is best effort only.
                }
            } finally {
                try {
                    releaseSchedulerAndContinue(
                            schedulerToken, activity, viewer, 0L, false);
                } finally {
                    dispatchManualFailure(viewer, targetId, diagnostic.stage());
                }
            }
        }
    }

    private static String manualCallbackKey(String viewer, String targetId) {
        return viewer + ":" + targetId;
    }

    private static void rememberResolvedAuthorModel(
            String viewer,
            String targetId,
            Object session,
            Object model) {
        if (!isDecimalId(viewer) || viewer.length() > 24
                || !isDecimalId(targetId) || targetId.length() > 24
                || session == null || model == null) {
            return;
        }
        synchronized (RESOLVED_AUTHOR_MODEL_LOCK) {
            long now = System.currentTimeMillis();
            pruneResolvedAuthorModelsLocked(now);
            RESOLVED_AUTHOR_MODELS.put(
                    resolvedAuthorModelKey(viewer, targetId),
                    new ResolvedAuthorModel(viewer, targetId, session, model, now));
            while (RESOLVED_AUTHOR_MODELS.size() > MAX_RESOLVED_AUTHOR_MODELS) {
                Iterator<Map.Entry<String, ResolvedAuthorModel>> iterator =
                        RESOLVED_AUTHOR_MODELS.entrySet().iterator();
                if (!iterator.hasNext()) {
                    break;
                }
                iterator.next();
                iterator.remove();
            }
        }
    }

    /**
     * Consumes a hint only after the durable queue-start and attempt reservation.
     * Missing, expired, or cross-session hints deliberately fall back to ID lookup.
     */
    private static Object takeResolvedAuthorModel(
            String viewer,
            String targetId,
            Object session) {
        synchronized (RESOLVED_AUTHOR_MODEL_LOCK) {
            pruneResolvedAuthorModelsLocked(System.currentTimeMillis());
            ResolvedAuthorModel hint = RESOLVED_AUTHOR_MODELS.remove(
                    resolvedAuthorModelKey(viewer, targetId));
            if (hint == null || hint.session != session
                    || !viewer.equals(hint.viewer)
                    || !targetId.equals(hint.targetId)) {
                return null;
            }
            return hint.model;
        }
    }

    private static void scopeResolvedAuthorModels(String viewer, Object session) {
        synchronized (RESOLVED_AUTHOR_MODEL_LOCK) {
            long now = System.currentTimeMillis();
            Iterator<Map.Entry<String, ResolvedAuthorModel>> iterator =
                    RESOLVED_AUTHOR_MODELS.entrySet().iterator();
            while (iterator.hasNext()) {
                ResolvedAuthorModel hint = iterator.next().getValue();
                if (isResolvedAuthorModelExpired(hint, now)
                        || !viewer.equals(hint.viewer)
                        || hint.session != session) {
                    iterator.remove();
                }
            }
        }
    }

    private static void clearResolvedAuthorModels() {
        synchronized (RESOLVED_AUTHOR_MODEL_LOCK) {
            RESOLVED_AUTHOR_MODELS.clear();
        }
    }

    private static void pruneResolvedAuthorModelsLocked(long now) {
        Iterator<Map.Entry<String, ResolvedAuthorModel>> iterator =
                RESOLVED_AUTHOR_MODELS.entrySet().iterator();
        while (iterator.hasNext()) {
            if (isResolvedAuthorModelExpired(iterator.next().getValue(), now)) {
                iterator.remove();
            }
        }
    }

    private static boolean isResolvedAuthorModelExpired(
            ResolvedAuthorModel hint, long now) {
        return hint == null || hint.createdAt <= 0L || now < hint.createdAt
                || now - hint.createdAt > RESOLVED_AUTHOR_MODEL_TTL_MS;
    }

    private static String resolvedAuthorModelKey(String viewer, String targetId) {
        return viewer + ":" + targetId;
    }

    private static final class ResolvedAuthorModel {
        final String viewer;
        final String targetId;
        final Object session;
        final Object model;
        final long createdAt;

        ResolvedAuthorModel(
                String viewer,
                String targetId,
                Object session,
                Object model,
                long createdAt) {
            this.viewer = viewer;
            this.targetId = targetId;
            this.session = session;
            this.model = model;
            this.createdAt = createdAt;
        }
    }

    private static void addManualCallback(String key, ManualBlockCallback callback) {
        if (callback == null) {
            return;
        }
        synchronized (MANUAL_CALLBACK_LOCK) {
            ArrayList<ManualBlockCallback> callbacks = MANUAL_CALLBACKS.get(key);
            if (callbacks == null) {
                callbacks = new ArrayList<ManualBlockCallback>();
                MANUAL_CALLBACKS.put(key, callbacks);
            }
            if (callbacks.size() < 4 && !callbacks.contains(callback)) {
                callbacks.add(callback);
            }
        }
    }

    private static void removeManualCallback(String key, ManualBlockCallback callback) {
        if (callback == null) {
            return;
        }
        synchronized (MANUAL_CALLBACK_LOCK) {
            ArrayList<ManualBlockCallback> callbacks = MANUAL_CALLBACKS.get(key);
            if (callbacks == null) {
                return;
            }
            callbacks.remove(callback);
            if (callbacks.isEmpty()) {
                MANUAL_CALLBACKS.remove(key);
            }
        }
    }

    private static ArrayList<ManualBlockCallback> takeManualCallbacks(
            String viewer, String targetId) {
        synchronized (MANUAL_CALLBACK_LOCK) {
            ArrayList<ManualBlockCallback> callbacks =
                    MANUAL_CALLBACKS.remove(manualCallbackKey(viewer, targetId));
            return callbacks == null
                    ? new ArrayList<ManualBlockCallback>() : callbacks;
        }
    }

    private static ArrayList<ManualBlockCallback> copyManualCallbacks(
            String viewer, String targetId) {
        synchronized (MANUAL_CALLBACK_LOCK) {
            ArrayList<ManualBlockCallback> callbacks =
                    MANUAL_CALLBACKS.get(manualCallbackKey(viewer, targetId));
            return callbacks == null
                    ? new ArrayList<ManualBlockCallback>()
                    : new ArrayList<ManualBlockCallback>(callbacks);
        }
    }

    private static void dispatchManualStarted(String viewer, String targetId) {
        for (ManualBlockCallback callback : copyManualCallbacks(viewer, targetId)) {
            try {
                callback.onManualBlockStarted(targetId);
            } catch (Throwable ignored) {
                // Inline UI callbacks are optional and may disappear with a recycled row.
            }
        }
    }

    private static void dispatchManualSuccess(String viewer, String targetId) {
        for (ManualBlockCallback callback : takeManualCallbacks(viewer, targetId)) {
            try {
                callback.onManualBlockSuccess(targetId);
            } catch (Throwable ignored) {
                // Persistence and the native mutation have already completed.
            }
        }
    }

    private static void dispatchManualFailure(String viewer, String targetId, String stage) {
        for (ManualBlockCallback callback : takeManualCallbacks(viewer, targetId)) {
            try {
                callback.onManualBlockFailure(targetId, stage);
            } catch (Throwable ignored) {
                // The durable queue/history state remains authoritative.
            }
        }
    }

    private static boolean requestForceRefresh(String viewer) {
        if (!isDecimalId(viewer) || viewer.length() > 24) {
            return false;
        }
        synchronized (FORCE_REFRESH_LOCK) {
            if (FORCE_REFRESH_VIEWERS.contains(viewer)) {
                return true;
            }
            if (FORCE_REFRESH_VIEWERS.size() >= MAX_PENDING_FORCE_VIEWERS) {
                Log.w(TAG, "Forced-refresh queue is full; preserved every existing viewer intent.");
                return false;
            }
            FORCE_REFRESH_VIEWERS.add(viewer);
            return true;
        }
    }

    private static boolean consumeForceRefresh(String viewer) {
        synchronized (FORCE_REFRESH_LOCK) {
            return FORCE_REFRESH_VIEWERS.remove(viewer);
        }
    }

    private static boolean requestListForceRefresh(String viewer) {
        if (!isDecimalId(viewer) || viewer.length() > 24) {
            return false;
        }
        synchronized (FORCE_REFRESH_LOCK) {
            if (LIST_FORCE_REFRESH_VIEWERS.contains(viewer)) {
                return true;
            }
            if (LIST_FORCE_REFRESH_VIEWERS.size() >= MAX_PENDING_FORCE_VIEWERS) {
                Log.w(TAG,
                        "List forced-refresh queue is full; preserved every existing viewer intent.");
                return false;
            }
            LIST_FORCE_REFRESH_VIEWERS.add(viewer);
            return true;
        }
    }

    private static boolean consumeListForceRefresh(String viewer) {
        synchronized (FORCE_REFRESH_LOCK) {
            return LIST_FORCE_REFRESH_VIEWERS.remove(viewer);
        }
    }

    private static boolean hasListForceRefresh(String viewer) {
        synchronized (FORCE_REFRESH_LOCK) {
            return LIST_FORCE_REFRESH_VIEWERS.contains(viewer);
        }
    }

    /**
     * Durably records every attempt before the bridge can dispatch. Passive attempts also
     * commit their randomly selected next-admission deadline in the same transaction. Manual
     * attempts intentionally bypass the passive delay configuration.
     */
    private static boolean reserveAttempt(Context context, String viewer, boolean automatic) {
        if (context == null || !isDecimalId(viewer) || viewer.length() > 24) {
            return false;
        }
        if (automatic && !BlockLimitsStore.isValid(context)) {
            return false;
        }
        SharedPreferences p = prefs(context);
        long now = System.currentTimeMillis();
        if (automatic && millisUntilPassivePaceAllowed(context, viewer) > 0L) {
            return false;
        }
        EventHistory eventHistory = readEvents(p, attemptsKey(viewer), now);
        if (!eventHistory.valid) {
            return false;
        }
        List<Long> events = eventHistory.events;
        events.add(Long.valueOf(now));
        while (events.size() > MAX_HISTORY_EVENTS) {
            events.remove(0);
        }
        SharedPreferences.Editor editor = p.edit()
                .putString(attemptsKey(viewer), encodeEvents(events))
                .remove(automaticAttemptsKey(viewer));
        if (automatic) {
            BlockLimits limits = BlockLimitsStore.load(context);
            long paceUntil = now + randomDelay(
                    limits.passiveMinDelayMs(), limits.passiveMaxDelayMs());
            editor.putLong(paceKey(viewer), paceUntil);
        }
        return editor.commit();
    }

    private static long millisUntilPassivePaceAllowed(Context context, String viewer) {
        if (context == null || !isDecimalId(viewer) || viewer.length() > 24) {
            return 0L;
        }
        SharedPreferences p = prefs(context);
        long now = System.currentTimeMillis();
        long maximumPace = BlockLimits.MAX_PASSIVE_MAX_DELAY_MS + 1000L;
        DeadlineState pace = readDeadline(p, paceKey(viewer), now, maximumPace);
        if (!pace.valid) {
            return SAFETY_REVIEW_WAKE_MS;
        }
        long paceUntil = pace.value;
        if (paceUntil <= now) {
            return 0L;
        }
        return paceUntil - now + 250L;
    }

    private static int randomDelay(int minimum, int maximum) {
        if (maximum <= minimum) {
            return minimum;
        }
        synchronized (RANDOM) {
            return minimum + RANDOM.nextInt(maximum - minimum + 1);
        }
    }

    private static String encodeEvents(List<Long> events) {
        StringBuilder encoded = new StringBuilder();
        for (Long event : events) {
            if (encoded.length() > 0) {
                encoded.append(',');
            }
            encoded.append(event.longValue());
        }
        return encoded.toString();
    }

    private static EventHistory readEvents(SharedPreferences p, String key, long now) {
        ArrayList<Long> events = new ArrayList<Long>();
        Map<String, ?> values = p.getAll();
        if (!values.containsKey(key)) {
            return EventHistory.valid(events);
        }
        Object stored = values.get(key);
        if (!(stored instanceof String)) {
            return EventHistory.invalid();
        }
        String raw = (String) stored;
        if (raw == null || raw.length() == 0) {
            return EventHistory.valid(events);
        }
        if (raw.length() > MAX_HISTORY_BYTES) {
            return EventHistory.invalid();
        }
        String[] pieces = raw.split(",", -1);
        if (pieces.length > MAX_HISTORY_EVENTS) {
            return EventHistory.invalid();
        }
        for (String piece : pieces) {
            try {
                if (!isUnsignedDecimal(piece)) {
                    return EventHistory.invalid();
                }
                long value = Long.parseLong(piece);
                if (value > now) {
                    return EventHistory.invalid();
                }
                if (value > now - HISTORY_RETENTION_MS) {
                    events.add(Long.valueOf(value));
                }
            } catch (NumberFormatException ignored) {
                return EventHistory.invalid();
            }
        }
        return EventHistory.valid(events);
    }

    private static final class EventHistory {
        final boolean valid;
        final List<Long> events;

        private EventHistory(boolean valid, List<Long> events) {
            this.valid = valid;
            this.events = events;
        }

        static EventHistory valid(List<Long> events) {
            return new EventHistory(true, events);
        }

        static EventHistory invalid() {
            return new EventHistory(false, new ArrayList<Long>());
        }
    }

    private static final class DeadlineState {
        final boolean valid;
        final long value;

        DeadlineState(boolean valid, long value) {
            this.valid = valid;
            this.value = value;
        }
    }

    private static DeadlineState readDeadline(
            SharedPreferences preferences, String key, long now, long maximumFutureMs) {
        if (preferences == null || key == null || now <= 0L || maximumFutureMs < 0L) {
            return new DeadlineState(false, 0L);
        }
        try {
            Map<String, ?> values = preferences.getAll();
            if (values == null) {
                return new DeadlineState(false, 0L);
            }
            if (!values.containsKey(key)) {
                return new DeadlineState(true, 0L);
            }
            Object raw = values.get(key);
            if (!(raw instanceof Long)) {
                return new DeadlineState(false, 0L);
            }
            long value = ((Long) raw).longValue();
            if (value < 0L || (value > now && value - now > maximumFutureMs)) {
                return new DeadlineState(false, 0L);
            }
            return new DeadlineState(true, value);
        } catch (Throwable ignored) {
            return new DeadlineState(false, 0L);
        }
    }

    private static DeadlineState readListRefreshDeadline(Context context, long now) {
        if (context == null || now <= 0L) {
            return new DeadlineState(false, 0L);
        }
        DeadlineState stored;
        try {
            stored = readDeadline(
                    prefs(context), KEY_LIST_REFRESH_NOT_BEFORE, now,
                    MAX_LIST_REFRESH_DEADLINE_FUTURE_MS);
        } catch (Throwable ignored) {
            return new DeadlineState(false, 0L);
        }
        if (!stored.valid) {
            return stored;
        }
        long local;
        synchronized (LIST_REFRESH_DEADLINE_LOCK) {
            local = localListRefreshNotBefore;
            if (local > now && local - now > MAX_LIST_REFRESH_DEADLINE_FUTURE_MS) {
                return new DeadlineState(false, 0L);
            }
            if (local <= now) {
                localListRefreshNotBefore = 0L;
                local = 0L;
            }
        }
        return new DeadlineState(true, Math.max(stored.value, local));
    }

    /**
     * Installs the process-local guard before attempting its durable typed commit. The
     * interval is FETCH_INTERVAL_MS before every attempt and after every successful one, or
     * one bounded failure-ladder step after a failed attempt; it never exceeds
     * FETCH_INTERVAL_MS, so a ladder deadline always passes the reader's future bound.
     */
    private static boolean advanceListRefreshDeadline(
            Context context, long now, long intervalMs) {
        if (context == null || now <= 0L || intervalMs <= 0L || intervalMs > FETCH_INTERVAL_MS
                || now > Long.MAX_VALUE - intervalMs) {
            return false;
        }
        long deadline = now + intervalMs;
        synchronized (LIST_REFRESH_DEADLINE_LOCK) {
            localListRefreshNotBefore = deadline;
        }
        try {
            return prefs(context).edit()
                    .putLong(KEY_LIST_REFRESH_NOT_BEFORE, deadline)
                    .commit();
        } catch (Throwable ignored) {
            return false;
        }
    }

    /** Ordinary 600,000 ms advance used before every attempt start and on start rejection. */
    private static boolean advanceListRefreshDeadline(Context context, long now) {
        return advanceListRefreshDeadline(context, now, FETCH_INTERVAL_MS);
    }

    /** Closed-class list fetch failure; only {@code failureClass} may reach status text. */
    static final class ListFetchFailure extends Exception {
        final String failureClass;

        ListFetchFailure(String failureClass, String detail) {
            super(detail);
            this.failureClass = failureClass;
        }
    }

    /** Transport failures are the IOException family; nothing else is retried in-attempt. */
    static boolean isTransportFailure(Throwable error) {
        return error instanceof IOException;
    }

    static String httpFailureClass(int status) {
        return status >= 100 && status <= 599
                ? FAILURE_HTTP_PREFIX + status : FAILURE_HTTP_PREFIX + "other";
    }

    /** Maps one mirror failure to a closed token by type only; never copies messages. */
    static String classifyListFetchFailure(Throwable error) {
        if (error instanceof ListFetchFailure) {
            return ((ListFetchFailure) error).failureClass;
        }
        if (error instanceof InterruptedIOException) {
            return FAILURE_TIMEOUT;
        }
        if (error instanceof SSLException) {
            return FAILURE_TLS;
        }
        if (error instanceof UnknownHostException || error instanceof SocketException) {
            return FAILURE_UNREACHABLE;
        }
        if (error instanceof IOException) {
            return FAILURE_IO;
        }
        if (error instanceof JSONException || error instanceof SecurityException) {
            return FAILURE_SCHEMA;
        }
        return FAILURE_INTERNAL;
    }

    /** Bounded "mirror 1 too_large, mirror 2 timeout, mirror 3 http_503" from closed tokens. */
    static String describeMirrorFailures(String[] mirrorFailures) {
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < mirrorFailures.length; i++) {
            if (text.length() > 0) {
                text.append(", ");
            }
            String failureClass = mirrorFailures[i];
            text.append("mirror ").append(i + 1).append(' ')
                    .append(failureClass == null ? FAILURE_INTERNAL : failureClass);
        }
        return text.toString();
    }

    /** Records one failed attempt; returns the bounded interval before the next attempt. */
    private static long recordListRefreshFailureAndNextIntervalMs() {
        synchronized (LIST_REFRESH_LADDER_LOCK) {
            if (listRefreshFailureStreak < MAX_LIST_REFRESH_FAILURE_RETRIES) {
                long intervalMs = LIST_REFRESH_FAILURE_LADDER_MS[listRefreshFailureStreak];
                listRefreshFailureStreak++;
                return intervalMs;
            }
            return FETCH_INTERVAL_MS;
        }
    }

    private static void resetListRefreshFailureLadder() {
        synchronized (LIST_REFRESH_LADDER_LOCK) {
            listRefreshFailureStreak = 0;
        }
    }

    /**
     * Main-thread only. Grants one deadline bypass per foreground session, only while no
     * verified index exists and only once the first ladder step has elapsed since the last
     * admitted start, so a fresh install or wiped store is not left waiting on a stale
     * not-before value while a pause/resume loop still cannot spam the mirrors.
     */
    private static boolean consumeMissingIndexResumeStart(Context context, long now) {
        if (!listRefreshResumeStartPending) {
            return false;
        }
        listRefreshResumeStartPending = false;
        if (listRefreshLastStartMs > 0L
                && now - listRefreshLastStartMs < LIST_REFRESH_FAILURE_LADDER_MS[0]) {
            return false;
        }
        try {
            BlocklistStore.Snapshot snapshot = BlocklistStore.snapshot(context);
            return snapshot == null || !snapshot.valid;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static DeadlineState readRetryDeadline(
            SharedPreferences preferences, String viewer, long now) {
        DeadlineState stored = readDeadline(
                preferences, retryKey(viewer), now, FAILURE_BACKOFF_MS + 5000L);
        if (!stored.valid) {
            return stored;
        }
        long local = 0L;
        synchronized (LOCAL_BACKOFF_LOCK) {
            Long value = LOCAL_FAILURE_BACKOFFS.get(viewer);
            if (value != null) {
                local = value.longValue();
                if (local <= now) {
                    LOCAL_FAILURE_BACKOFFS.remove(viewer);
                    local = 0L;
                }
            }
        }
        return new DeadlineState(true, Math.max(stored.value, local));
    }

    /** Establishes a process-local fail-closed deadline before attempting durable persistence. */
    private static boolean persistRetryDeadline(Context context, String viewer) {
        if (context == null || !isDecimalId(viewer) || viewer.length() > 24) {
            return false;
        }
        long deadline = System.currentTimeMillis() + FAILURE_BACKOFF_MS;
        synchronized (LOCAL_BACKOFF_LOCK) {
            LOCAL_FAILURE_BACKOFFS.put(viewer, Long.valueOf(deadline));
        }
        return prefs(context).edit().putLong(retryKey(viewer), deadline).commit();
    }

    private static boolean clearRetryDeadline(Context context, String viewer) {
        if (context == null || !isDecimalId(viewer) || viewer.length() > 24) {
            return false;
        }
        boolean committed = prefs(context).edit().remove(retryKey(viewer)).commit();
        if (committed) {
            synchronized (LOCAL_BACKOFF_LOCK) {
                LOCAL_FAILURE_BACKOFFS.remove(viewer);
            }
        }
        return committed;
    }

    /**
     * Installs a process-local fail-closed latch before attempting durable
     * viewer/target quarantine persistence.
     */
    private static boolean quarantineCompletionReview(
            Context context, String viewer, String targetId) {
        installLocalCompletionReview(viewer, targetId);
        boolean saved = false;
        try {
            saved = ModStateStore.quarantineCompletionReview(
                    context, viewer, targetId);
        } catch (Throwable ignored) {
            // Keep the process-local viewer/target latch and report fail-closed state.
        }
        if (saved) {
            HashSet<String> targets = new HashSet<String>();
            targets.add(targetId);
            clearLocalCompletionReviewAfterRetry(viewer, targets);
        }
        return saved;
    }

    private static void installLocalCompletionReview(String viewer, String targetId) {
        synchronized (COMPLETION_REVIEW_LOCK) {
            String key = completionReviewTargetKey(viewer, targetId);
            if (LOCAL_COMPLETION_REVIEW_TARGETS.contains(key)
                    || LOCAL_COMPLETION_REVIEW_TARGETS.size()
                    < ModStateStore.MAX_COMPLETION_REVIEW_TARGETS) {
                LOCAL_COMPLETION_REVIEW_TARGETS.add(key);
            } else {
                localCompletionReviewOverflow = true;
            }
            if (LOCAL_COMPLETION_REVIEW_PAUSED_VIEWERS.contains(viewer)
                    || LOCAL_COMPLETION_REVIEW_PAUSED_VIEWERS.size()
                    < MAX_LOCAL_COMPLETION_REVIEW_VIEWERS) {
                LOCAL_COMPLETION_REVIEW_PAUSED_VIEWERS.add(viewer);
            } else {
                localCompletionReviewOverflow = true;
            }
        }
    }

    /** Called only after an explicit retry or durable quarantine commit succeeds. */
    static void clearLocalCompletionReviewAfterRetry(
            String viewer, Set<String> targetIds) {
        if (!isDecimalId(viewer) || viewer.length() > 24
                || targetIds == null || targetIds.isEmpty()) {
            return;
        }
        synchronized (COMPLETION_REVIEW_LOCK) {
            for (String targetId : targetIds) {
                if (isDecimalId(targetId) && targetId.length() <= 24) {
                    LOCAL_COMPLETION_REVIEW_TARGETS.remove(
                            completionReviewTargetKey(viewer, targetId));
                }
            }
            String prefix = viewer + ":";
            boolean viewerStillLatched = false;
            for (String key : LOCAL_COMPLETION_REVIEW_TARGETS) {
                if (key.startsWith(prefix)) {
                    viewerStillLatched = true;
                    break;
                }
            }
            if (!viewerStillLatched) {
                LOCAL_COMPLETION_REVIEW_PAUSED_VIEWERS.remove(viewer);
            }
        }
    }

    private static boolean isLocalCompletionReviewPaused(String viewer) {
        synchronized (COMPLETION_REVIEW_LOCK) {
            return localCompletionReviewOverflow
                    || LOCAL_COMPLETION_REVIEW_PAUSED_VIEWERS.contains(viewer);
        }
    }

    private static String completionReviewTargetKey(String viewer, String targetId) {
        return viewer + ":" + targetId;
    }

    private static boolean isUnsignedDecimal(String value) {
        if (value == null || value.length() == 0 || value.length() > 19) {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c < '0' || c > '9') {
                return false;
            }
        }
        return true;
    }

    /** Exactly 64 lowercase hexadecimal characters: a content-addressed object name stem. */
    private static boolean isLowercaseHexDigest(String value) {
        if (value == null || value.length() != 64) {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            boolean allowed = c >= '0' && c <= '9' || c >= 'a' && c <= 'f';
            if (!allowed) {
                return false;
            }
        }
        return true;
    }

    private static Set<String> doneIds(Context context, String viewer) {
        return ModStateStore.doneIdsForScheduler(context, viewer);
    }

    private static boolean markDone(Context context, String viewer, String targetId) {
        return ModStateStore.markAutomaticDone(context, viewer, targetId);
    }

    static boolean isDecimalId(String value) {
        if (value == null || value.length() < 4) {
            return false;
        }
        if (value.charAt(0) == '0') {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c < '0' || c > '9') {
                return false;
            }
        }
        return true;
    }

    private static boolean isMainLooperThread() {
        return Looper.myLooper() == Looper.getMainLooper();
    }

    private static long parseInstant(String value) {
        if (value == null || value.length() == 0) {
            return 0L;
        }
        try {
            return Instant.parse(value).toEpochMilli();
        } catch (Throwable ignored) {
            return 0L;
        }
    }

    private static String viewerId(Object userSession) {
        if (userSession == null) {
            return null;
        }
        try {
            Field field;
            try {
                field = userSession.getClass().getField("userId");
            } catch (NoSuchFieldException publicMiss) {
                field = userSession.getClass().getDeclaredField("userId");
                field.setAccessible(true);
            }
            Object value = field.get(userSession);
            return value == null ? null : String.valueOf(value);
        } catch (Throwable fieldMiss) {
            try {
                Method method = userSession.getClass().getMethod("getUserId");
                Object value = method.invoke(userSession);
                return value == null ? null : String.valueOf(value);
            } catch (Throwable ignored) {
                return null;
            }
        }
    }

    private static SharedPreferences prefs(Context context) {
        return context.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static void setStatus(Context context, String viewer, String status) {
        if (context == null) {
            return;
        }
        String safe = status == null ? "Unknown status" : status;
        if (safe.length() > 240) {
            safe = safe.substring(0, 240);
        }
        prefs(context).edit().putString(statusKey(viewer), safe).apply();
    }

    private static void showToast(final Context context, final String message) {
        MAIN.post(new Runnable() {
            @Override
            public void run() {
                try {
                    Toast.makeText(context.getApplicationContext(), message, Toast.LENGTH_LONG).show();
                } catch (Throwable ignored) {
                    // Optional UI must never affect Threads startup.
                }
            }
        });
    }

    private static String attemptsKey(String viewer) {
        return "attempts_threads_" + viewer;
    }

    private static String automaticAttemptsKey(String viewer) {
        return "automatic_attempts_threads_" + viewer;
    }

    private static String paceKey(String viewer) {
        return "pace_until_threads_" + viewer;
    }

    private static String retryKey(String viewer) {
        return "retry_threads_" + viewer;
    }

    private static String statusKey(String viewer) {
        return isDecimalId(viewer) && viewer.length() <= 24
                ? KEY_STATUS + "_threads_" + viewer : KEY_STATUS + "_general";
    }
}
