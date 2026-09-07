package threadsmod.bootstrap;

import android.app.Activity;


import java.lang.ref.WeakReference;

import threadsmod.autoblock.AutoBlockSync;
import threadsmod.reporting.InstallStats;
import threadsmod.reporting.ReportClient;
import threadsmod.update.UpdateController;

/**
 * Stable host hook for all patchlet features.
 *
 * Future features should register here in deterministic patchlet order instead
 * of adding another direct hook to the obfuscated Threads activity.
 */
public final class ModBootstrap {
    private static final Object REPORT_OWNER_LOCK = new Object();
    private static WeakReference<Activity> reportOwnerActivity =
            new WeakReference<Activity>(null);
    private static ReportClient.ForegroundOwner reportOwner;

    private ModBootstrap() {}

    public static void onResume(Activity activity, Object userSession) {
        AutoBlockSync.onResume(activity, userSession);
        ReportClient.ForegroundOwner owner =
                ReportClient.onForeground(activity, AutoBlockSync.getCurrentViewer());
        synchronized (REPORT_OWNER_LOCK) {
            reportOwnerActivity = new WeakReference<Activity>(activity);
            reportOwner = owner;
        }
        if (AutoBlockSync.isEnabled(activity)) {
            // Once per installed build. Passive blocking is always on, and the Settings
            // screen's Reports card discloses this ping before a later build can send another.
            InstallStats.maybeSend(activity);
        }
        // Update arbitration runs first on every resume. Its no-update continuation is
        // deliberately empty: the first-run dialog it used to show is gone, and disclosure
        // lives in the Settings screen. The release gate proves this Runnable captures
        // nothing and does nothing, so nothing can be drawn over a required update dialog.
        UpdateController.onResume(activity, new Runnable() {
            @Override
            public void run() {
            }
        });
    }

    public static void onPause(Activity activity) {
        UpdateController.onPause(activity);
        ReportClient.ForegroundOwner owner = null;
        synchronized (REPORT_OWNER_LOCK) {
            if (reportOwnerActivity.get() == activity) {
                owner = reportOwner;
                reportOwner = null;
                reportOwnerActivity = new WeakReference<Activity>(null);
            }
        }
        ReportClient.onBackground(owner);
        AutoBlockSync.onPause(activity);
    }
}
