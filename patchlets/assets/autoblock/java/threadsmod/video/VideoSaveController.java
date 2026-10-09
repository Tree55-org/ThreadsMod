package threadsmod.video;

import android.app.Activity;
import android.content.Intent;
import android.os.Looper;

/** Opens a private save surface only from the explicit media-row action. */
public final class VideoSaveController {
    static final String EXTRA_URL = "threadsmod.video.url";
    static final String EXTRA_FILENAME = "threadsmod.video.filename";

    private VideoSaveController() {}

    public static boolean open(Activity activity, String url) {
        if (Looper.myLooper() != Looper.getMainLooper() || activity == null
                || activity.isFinishing() || activity.isDestroyed()) return false;
        try {
            VideoSaveRequest request = new VideoSaveRequest(
                    url, "Threads-video-" + System.currentTimeMillis() + ".mp4");
            Intent intent = new Intent(activity, VideoSaveActivity.class);
            intent.putExtra(EXTRA_URL, request.url);
            intent.putExtra(EXTRA_FILENAME, request.suggestedFilename);
            activity.startActivity(intent);
            return true;
        } catch (RuntimeException unavailable) {
            return false;
        }
    }
}
