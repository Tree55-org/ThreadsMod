package threadsmod.autoblock;

import android.os.Handler;
import android.os.Looper;

/**
 * Posts every native-bridge callback beyond the private Threads call stack.
 *
 * A reviewed Threads mutation invokes its started callback synchronously. The
 * Smali bridge calls this dispatcher instead of invoking a mod callback from
 * that host stack, so a mod callback failure cannot be caught and mislabeled
 * as a private-seam failure.
 */
public final class BridgeCallbackDispatcher {
    private static final int STARTED = 1;
    private static final int FAILURE = 2;
    private static final int SUCCESS = 3;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    private BridgeCallbackDispatcher() {}

    public static void started(BridgeCallback callback, String targetId) {
        enqueue(callback, targetId, null, STARTED);
    }

    public static void failure(BridgeCallback callback, String targetId, String stage) {
        enqueue(callback, targetId, stage, FAILURE);
    }

    public static void success(BridgeCallback callback, String targetId) {
        enqueue(callback, targetId, null, SUCCESS);
    }

    private static void enqueue(
            BridgeCallback callback,
            String targetId,
            String stage,
            int kind) {
        if (callback == null || targetId == null || (kind == FAILURE && stage == null)) {
            throw new IllegalArgumentException();
        }
        if (!MAIN.post(new Delivery(callback, targetId, stage, kind))) {
            throw new IllegalStateException();
        }
    }

    private static final class Delivery implements Runnable {
        private final BridgeCallback callback;
        private final String targetId;
        private final String stage;
        private final int kind;

        Delivery(BridgeCallback callback, String targetId, String stage, int kind) {
            this.callback = callback;
            this.targetId = targetId;
            this.stage = stage;
            this.kind = kind;
        }

        @Override
        public void run() {
            if (kind == STARTED) {
                callback.onBridgeStarted(targetId);
            } else if (kind == FAILURE) {
                callback.onBridgeFailure(targetId, stage);
            } else if (kind == SUCCESS) {
                callback.onBridgeSuccess(targetId);
            }
        }
    }
}
