package threadsmod.autoblock;

/** Callback from the serialized manual block scheduler to stable inline UI code. */
public interface ManualBlockCallback {
    void onManualBlockQueued(String targetId);

    void onManualBlockStarted(String targetId);

    void onManualBlockSuccess(String targetId);

    void onManualBlockFailure(String targetId, String stage);
}
