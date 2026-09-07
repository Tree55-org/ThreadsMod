package threadsmod.inlinecontrol;

/** Host-renderer boundary for inline Block state and dismissal animation. */
public interface InlineBlockUiCallback {
    /** A durable viewer-scoped queue entry now exists. */
    void onQueued(InlineBlockRequest request);

    /** Threads' native block request has actually started. */
    void onStarted(InlineBlockRequest request);

    /** Threads' native callback confirmed success. */
    void onSuccess(InlineBlockRequest request);

    /** Validation, scheduling, or Threads' native request failed. */
    void onFailure(InlineBlockRequest request, String stage);

    /** The user dismissed the confirmation dialog without an account mutation. */
    void onCancelled(InlineBlockRequest request);

    /** Start the host row's dismissal animation after the success hold. */
    void onDismiss(InlineBlockRequest request);
}
