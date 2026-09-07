package threadsmod.autoblock;

/** Callback boundary implemented by the Java queue and called from the smali bridge. */
public interface BridgeCallback {
    void onBridgeStarted(String targetId);

    void onBridgeSuccess(String targetId);

    void onBridgeFailure(String targetId, String stage);
}
