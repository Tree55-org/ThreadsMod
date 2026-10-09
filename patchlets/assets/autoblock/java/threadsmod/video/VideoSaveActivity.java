package threadsmod.video;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.IOException;
import java.io.OutputStream;

/** Resource-free, non-exported, user-selected document save surface. */
public final class VideoSaveActivity extends Activity {
    private static final int CREATE_VIDEO_DOCUMENT = 7501;
    private static final String STATE_PICKING = "threadsmod.video.picking";
    private static final String STATE_INTERRUPTED = "threadsmod.video.interrupted";
    private VideoSaveRequest request;
    private Button choose;
    private TextView status;
    private boolean picking;
    private volatile boolean destroyed;
    private volatile Thread worker;
    private VideoTransfer.Cancellation cancellation;
    private final Handler main = new Handler(Looper.getMainLooper());

    @Override protected void onCreate(Bundle savedInstanceState) {
        setTheme(android.R.style.Theme_DeviceDefault_NoActionBar);
        super.onCreate(savedInstanceState);
        setTitle("Save video");
        attachShell();
        try {
            String url;
            String filename;
            if (savedInstanceState != null) {
                url = savedInstanceState.getString(VideoSaveController.EXTRA_URL);
                filename = savedInstanceState.getString(VideoSaveController.EXTRA_FILENAME);
                picking = savedInstanceState.getBoolean(STATE_PICKING, false);
            } else {
                Intent intent = getIntent();
                url = intent == null ? null : intent.getStringExtra(VideoSaveController.EXTRA_URL);
                filename = intent == null ? null : intent.getStringExtra(VideoSaveController.EXTRA_FILENAME);
            }
            request = new VideoSaveRequest(url, filename);
            choose.setEnabled(!picking);
            status.setText(savedInstanceState != null && savedInstanceState.getBoolean(STATE_INTERRUPTED, false)
                    ? "Save interrupted. Choose another location to try again."
                    : "The video is downloaded only after you choose a location.");
        } catch (RuntimeException unavailable) {
            request = null;
            picking = false;
            choose.setEnabled(false);
            status.setText("Video unavailable.");
        }
    }

    private void attachShell() {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int padding = (int) (24 * getResources().getDisplayMetrics().density + 0.5f);
        root.setPadding(padding, padding, padding, padding);
        TextView heading = new TextView(this);
        heading.setText("Save video");
        heading.setTextSize(26);
        root.addView(heading, rowParams());
        TextView helper = new TextView(this);
        helper.setText("Choose where to save this MP4.");
        helper.setTextSize(16);
        root.addView(helper, rowParams());
        choose = new Button(this);
        choose.setText("Choose location");
        choose.setEnabled(false);
        root.addView(choose, rowParams());
        status = new TextView(this);
        status.setText("Video unavailable.");
        root.addView(status, rowParams());
        scroll.addView(root, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        // Keep the exact shell visible even when extras are missing, mistyped or corrupt.
        setContentView(scroll);
        choose.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View view) { chooseLocation(); }
        });
    }

    private LinearLayout.LayoutParams rowParams() {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.bottomMargin = (int) (12 * getResources().getDisplayMetrics().density + 0.5f);
        return params;
    }

    private void chooseLocation() {
        if (request == null || picking || worker != null || destroyed) return;
        try {
            Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType("video/mp4");
            intent.putExtra(Intent.EXTRA_TITLE, request.suggestedFilename);
            picking = true;
            choose.setEnabled(false);
            status.setText("Choose a location in the system picker.");
            startActivityForResult(intent, CREATE_VIDEO_DOCUMENT);
        } catch (RuntimeException unavailable) {
            picking = false;
            choose.setEnabled(true);
            status.setText("The system save picker is unavailable.");
        }
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != CREATE_VIDEO_DOCUMENT || !picking || destroyed) return;
        picking = false;
        choose.setEnabled(request != null);
        if (resultCode != RESULT_OK || data == null) {
            status.setText("Save cancelled.");
            return;
        }
        Uri destination = data.getData();
        if (request == null || destination == null || !"content".equals(destination.getScheme())
                || destination.toString().length() > 4096) {
            status.setText("Save location unavailable.");
            return;
        }
        saveTo(destination);
    }

    private void saveTo(final Uri destination) {
        if (worker != null || destroyed) return;
        choose.setEnabled(false);
        status.setText("Saving video…");
        cancellation = new VideoTransfer.Cancellation();
        final VideoTransfer.Cancellation current = cancellation;
        final VideoSaveRequest immutableRequest = request;
        final CancellationSignal providerCancellation = new CancellationSignal();
        final VideoTransfer.Destination output = new VideoTransfer.Destination() {
            @Override public OutputStream open() throws IOException {
                ParcelFileDescriptor file = getContentResolver().openFileDescriptor(
                        destination, "wt", providerCancellation);
                if (file == null) throw new IOException("video destination unavailable");
                return new ParcelFileDescriptor.AutoCloseOutputStream(file);
            }
            @Override public void cancel() { providerCancellation.cancel(); }
            @Override public void discard() {
                try { DocumentsContract.deleteDocument(getContentResolver(), destination); }
                catch (Exception ignored) {}
            }
        };
        worker = new Thread(new Runnable() {
            @Override public void run() {
                boolean saved = false;
                try {
                    VideoTransfer.save(immutableRequest, getCacheDir(), output, current);
                    saved = true;
                } catch (Exception unavailable) {
                    // Fixed status only: URLs, provider paths and exception text remain private.
                }
                final boolean completed = saved;
                worker = null;
                if (!main.post(new Runnable() {
                    @Override public void run() {
                        if (destroyed || isFinishing() || isDestroyed()) return;
                        choose.setEnabled(request != null);
                        status.setText(completed ? "Video saved." : "Video could not be saved. Choose another location to try again.");
                    }
                })) {
                    current.cancel();
                }
            }
        }, "ThreadsModVideoSave");
        worker.setDaemon(true);
        try {
            worker.start();
        } catch (RuntimeException rejected) {
            worker = null;
            current.cancel();
            // Cleanup may involve a document provider, so keep it off the UI thread.
            Thread cleanup = new Thread(new Runnable() {
                @Override public void run() { output.discard(); }
            }, "ThreadsModVideoCleanup");
            cleanup.setDaemon(true);
            try { cleanup.start(); } catch (RuntimeException ignored) {}
            choose.setEnabled(request != null);
            status.setText("Video could not be saved. Choose another location to try again.");
        }
    }

    @Override protected void onSaveInstanceState(Bundle state) {
        if (request != null) {
            state.putString(VideoSaveController.EXTRA_URL, request.url);
            state.putString(VideoSaveController.EXTRA_FILENAME, request.suggestedFilename);
        }
        state.putBoolean(STATE_PICKING, picking);
        state.putBoolean(STATE_INTERRUPTED, worker != null);
        super.onSaveInstanceState(state);
    }

    @Override protected void onDestroy() {
        destroyed = true;
        if (cancellation != null) cancellation.cancel();
        Thread active = worker;
        if (active != null) {
            active.interrupt();
            // Provider cancellation and stream closing can use Binder or block; keep them off main.
            final VideoTransfer.Cancellation current = cancellation;
            Thread abort = new Thread(new Runnable() {
                @Override public void run() { if (current != null) current.abort(); }
            }, "ThreadsModVideoCancel");
            abort.setDaemon(true);
            try { abort.start(); } catch (RuntimeException ignored) {}
        }
        super.onDestroy();
    }
}
