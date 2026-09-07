package threadsmod.update;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.view.View;
import android.widget.Button;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.lang.ref.WeakReference;
import java.lang.reflect.Method;
import java.net.CookieHandler;
import java.net.URL;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Timer;
import java.util.TimerTask;

import javax.net.ssl.HttpsURLConnection;

/** Foreground update checker, policy dialog, verified downloader and installer handoff. */
public final class UpdateController {
    public static final long CURRENT_MOD_BUILD = 1L;
    private static final String FILE_PROVIDER_AUTHORITY =
            "app.tree55.threads.fileprovider";
    private static final String CACHE_APK_NAME = "threadsmod-update.apk";
    private static final String CACHE_PART_NAME = "threadsmod-update.apk.part";
    private static final long CHECK_INTERVAL_MS = 10L * 60L * 1000L;
    private static final long MAX_CHECK_DEADLINE_FUTURE_MS =
            CHECK_INTERVAL_MS + 10L * 60L * 1000L;
    private static final int MAX_METADATA_BYTES = 24 * 1024;
    private static final long METADATA_ATTEMPT_TIMEOUT_MS = 8000L;
    private static final long METADATA_OPERATION_TIMEOUT_MS = 24000L;
    private static final long DOWNLOAD_ATTEMPT_TIMEOUT_MS = 10L * 60L * 1000L;
    private static final long DOWNLOAD_OPERATION_TIMEOUT_MS = 20L * 60L * 1000L;
    private static final String USER_AGENT = "ThreadsMod-Updater/1";
    private static final Object LOCK = new Object();
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static WeakReference<Activity> owner = new WeakReference<Activity>(null);
    private static long ownerGeneration;
    private static Runnable fallback;
    private static AlertDialog dialog;
    private static Runnable checkWake;
    private static boolean checkInFlight;
    private static long dialogOwnerGeneration;
    private static boolean dialogRequired;
    private static boolean downloadInFlight;
    private static long downloadToken;
    private static UpdateManifest downloadManifest;
    private static WeakReference<Activity> downloadAuthorizedActivity =
            new WeakReference<Activity>(null);
    private static long downloadAuthorizedGeneration;
    private static AlertDialog downloadAuthorizedDialog;

    private UpdateController() {}

    /**
     * Owns initial-dialog arbitration. The fallback is invoked only when no update UI applies.
     */
    public static void onResume(final Activity activity, final Runnable noUpdateFallback) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            MAIN.post(new Runnable() {
                @Override public void run() { onResume(activity, noUpdateFallback); }
            });
            return;
        }
        if (!isUsable(activity)) return;
        if (!UpdateManifest.APPLICATION_ID.equals(activity.getPackageName())) {
            if (noUpdateFallback != null) noUpdateFallback.run();
            return;
        }
        final long generation;
        synchronized (LOCK) {
            owner = new WeakReference<Activity>(activity);
            ownerGeneration++;
            generation = ownerGeneration;
            fallback = noUpdateFallback;
        }
        long now = System.currentTimeMillis();
        UpdateManifest cached = null;
        boolean retainedRequiredOnly = false;
        try {
            cached = UpdateStore.load(activity, now);
        } catch (Throwable corrupt) {
            retainedRequiredOnly = UpdateStore.hasRetainedRequiredForEnforcement(
                    CURRENT_MOD_BUILD);
        }
        boolean requiredPresented;
        if (retainedRequiredOnly) {
            showRetainedRequiredUnavailable(activity, generation);
            requiredPresented = true;
        } else {
            requiredPresented = cached != null
                    && CURRENT_MOD_BUILD < cached.minimumModBuild
                    && presentIfApplicable(activity, generation, cached);
        }
        final long deadline;
        try {
            deadline = UpdateStore.checkNotBefore(
                    activity, now, MAX_CHECK_DEADLINE_FUTURE_MS);
        } catch (Throwable corrupt) {
            if (now <= Long.MAX_VALUE - CHECK_INTERVAL_MS
                    && UpdateStore.setCheckNotBefore(activity, now + CHECK_INTERVAL_MS)) {
                scheduleCheckWake(activity, generation, CHECK_INTERVAL_MS);
                startCheck(activity.getApplicationContext());
            } else if (!requiredPresented) {
                scheduleCheckWake(activity, generation, CHECK_INTERVAL_MS);
                runFallback(activity, generation);
            }
            return;
        }
        if (now < deadline) {
            scheduleCheckWake(activity, generation, deadline - now);
            if (!requiredPresented && !presentIfApplicable(activity, generation, cached)) {
                runFallback(activity, generation);
            }
            return;
        }
        if (now > Long.MAX_VALUE - CHECK_INTERVAL_MS
                || !UpdateStore.setCheckNotBefore(activity, now + CHECK_INTERVAL_MS)) {
            scheduleCheckWake(activity, generation, CHECK_INTERVAL_MS);
            if (!requiredPresented) {
                runFallback(activity, generation);
            }
            return;
        }
        scheduleCheckWake(activity, generation, CHECK_INTERVAL_MS);
        startCheck(activity.getApplicationContext());
    }

    public static void onPause(Activity activity) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            MAIN.post(new Runnable() {
                @Override public void run() { onPause(activity); }
            });
            return;
        }
        synchronized (LOCK) {
            if (owner.get() != activity) return;
            owner = new WeakReference<Activity>(null);
            ownerGeneration++;
            fallback = null;
            if (checkWake != null) {
                MAIN.removeCallbacks(checkWake);
                checkWake = null;
            }
            if (dialog != null) {
                dialog.dismiss();
                dialog = null;
                dialogOwnerGeneration = 0L;
                dialogRequired = false;
            }
            if (downloadAuthorizedActivity.get() == activity) {
                downloadAuthorizedActivity = new WeakReference<Activity>(null);
                downloadAuthorizedGeneration = 0L;
                downloadAuthorizedDialog = null;
            }
        }
    }

    private static void scheduleCheckWake(
            final Activity activity, final long generation, long delayMs) {
        if (!isCurrentOwner(activity, generation)) return;
        final Runnable wake = new Runnable() {
            @Override public void run() {
                synchronized (LOCK) {
                    if (checkWake != this) return;
                    checkWake = null;
                }
                runScheduledCheck(activity, generation);
            }
        };
        synchronized (LOCK) {
            if (checkWake != null) MAIN.removeCallbacks(checkWake);
            checkWake = wake;
        }
        boolean accepted = MAIN.postDelayed(wake, Math.max(1L, delayMs));
        if (!accepted) {
            synchronized (LOCK) {
                if (checkWake == wake) checkWake = null;
            }
        }
    }

    private static void runScheduledCheck(Activity activity, long generation) {
        if (!isCurrentOwner(activity, generation)) return;
        long now = System.currentTimeMillis();
        long deadline;
        try {
            deadline = UpdateStore.checkNotBefore(
                    activity, now, MAX_CHECK_DEADLINE_FUTURE_MS);
        } catch (Throwable corrupt) {
            deadline = 0L;
        }
        if (now < deadline) {
            scheduleCheckWake(activity, generation, deadline - now);
            return;
        }
        if (now <= Long.MAX_VALUE - CHECK_INTERVAL_MS
                && UpdateStore.setCheckNotBefore(activity, now + CHECK_INTERVAL_MS)) {
            startCheck(activity.getApplicationContext());
        }
        scheduleCheckWake(activity, generation, CHECK_INTERVAL_MS);
    }

    private static void startCheck(final Context context) {
        synchronized (LOCK) {
            if (checkInFlight) return;
            checkInFlight = true;
        }
        try {
            Thread worker = new Thread(new Runnable() {
            @Override public void run() {
                UpdateManifest result = null;
                Throwable failure = null;
                try {
                    result = fetchHighest(context);
                    if (result != null) {
                        result = UpdateStore.installVerified(
                                context, result, System.currentTimeMillis());
                    } else {
                        result = UpdateStore.load(context, System.currentTimeMillis());
                    }
                } catch (Throwable invalid) {
                    failure = invalid;
                }
                final UpdateManifest completed = result;
                final Throwable completedFailure = failure;
                synchronized (LOCK) { checkInFlight = false; }
                MAIN.post(new Runnable() {
                    @Override public void run() {
                        Activity activity;
                        long generation;
                        synchronized (LOCK) {
                            activity = owner.get();
                            generation = ownerGeneration;
                        }
                        if (!isUsable(activity)) return;
                        if (completedFailure != null) {
                            UpdateManifest retained;
                            try {
                                retained = UpdateStore.load(activity, System.currentTimeMillis());
                            } catch (Throwable corrupt) {
                                retained = null;
                                if (UpdateStore.hasRetainedRequiredForEnforcement(
                                        CURRENT_MOD_BUILD)) {
                                    showRetainedRequiredUnavailable(activity, generation);
                                    return;
                                }
                            }
                            if (presentIfApplicable(activity, generation, retained)) return;
                            runFallback(activity, generation);
                            return;
                        }
                        if (!presentIfApplicable(activity, generation, completed)) {
                            runFallback(activity, generation);
                        }
                    }
                });
            }
            }, "ThreadsModUpdateCheck");
            worker.start();
        } catch (Throwable rejected) {
            synchronized (LOCK) { checkInFlight = false; }
            handleCheckStartFailure();
        }
    }

    private static void handleCheckStartFailure() {
        Activity activity;
        long generation;
        synchronized (LOCK) {
            activity = owner.get();
            generation = ownerGeneration;
        }
        if (!isUsable(activity)) return;
        UpdateManifest retained;
        try {
            retained = UpdateStore.load(activity, System.currentTimeMillis());
        } catch (Throwable corrupt) {
            retained = null;
            if (UpdateStore.hasRetainedRequiredForEnforcement(CURRENT_MOD_BUILD)) {
                showRetainedRequiredUnavailable(activity, generation);
                return;
            }
        }
        if (retained != null && CURRENT_MOD_BUILD < retained.minimumModBuild) {
            presentIfApplicable(activity, generation, retained);
        } else {
            runFallback(activity, generation);
        }
    }

    private static UpdateManifest fetchHighest(Context context) throws Exception {
        UpdateEndpoints.validateConfiguration();
        List<UpdateManifest> valid = new ArrayList<UpdateManifest>();
        long operationDeadline = deadlineAfter(METADATA_OPERATION_TIMEOUT_MS);
        for (int i = 0; i < UpdateEndpoints.metadataMirrorCount(); i++) {
            if (isExpired(operationDeadline)) break;
            HttpsURLConnection connection = null;
            Timer deadlineDisconnect = null;
            long attemptDeadline = Math.min(
                    operationDeadline, deadlineAfter(METADATA_ATTEMPT_TIMEOUT_MS));
            try {
                connection = openIsolated(UpdateEndpoints.metadataMirror(i));
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(timeoutBefore(attemptDeadline, 3000));
                connection.setReadTimeout(timeoutBefore(attemptDeadline, 5000));
                connection.setUseCaches(false);
                connection.setRequestMethod("GET");
                connection.setRequestProperty("User-Agent", USER_AGENT);
                connection.setRequestProperty("Accept", "application/json");
                connection.setRequestProperty("Accept-Encoding", "identity");
                deadlineDisconnect = disconnectAtDeadline(connection, attemptDeadline);
                requireIsolatedHttp();
                connection.setReadTimeout(timeoutBefore(attemptDeadline, 5000));
                int status = connection.getResponseCode();
                if (status != HttpsURLConnection.HTTP_OK) continue;
                long length = connection.getContentLengthLong();
                if (length > MAX_METADATA_BYTES) continue;
                requireIsolatedHttp();
                byte[] bytes = readBounded(
                        connection, connection.getInputStream(),
                        MAX_METADATA_BYTES, attemptDeadline, 5000);
                String body = UpdateJson.decodeUtf8(bytes);
                if (body == null) continue;
                valid.add(UpdateManifest.parseAndVerify(body, System.currentTimeMillis()));
            } catch (Throwable ignoredMirror) {
                // All three mirrors are always attempted; one blocked origin is not terminal.
            } finally {
                if (deadlineDisconnect != null) deadlineDisconnect.cancel();
                if (connection != null) connection.disconnect();
            }
        }
        UpdateManifest highest = null;
        for (UpdateManifest candidate : valid) {
            if (highest == null || candidate.revision > highest.revision) {
                highest = candidate;
            }
        }
        if (highest != null) {
            for (UpdateManifest candidate : valid) {
                if (candidate.revision == highest.revision
                        && !candidate.sameSignedRelease(highest)) {
                    throw new SecurityException("update mirrors equivocate at highest revision");
                }
            }
        }
        return highest;
    }

    private static boolean presentIfApplicable(
            Activity activity, long generation, UpdateManifest manifest) {
        if (manifest == null || !isCurrentOwner(activity, generation)) return false;
        boolean required = CURRENT_MOD_BUILD < manifest.minimumModBuild;
        long installedVersion;
        try {
            PackageInfo current = activity.getPackageManager().getPackageInfo(
                    UpdateManifest.APPLICATION_ID, PackageManager.GET_SIGNING_CERTIFICATES);
            installedVersion = current.getLongVersionCode();
        } catch (Throwable invalidPackage) {
            if (required) {
                showUnavailable(activity, generation, "Installed package version cannot be verified.");
                return true;
            }
            return false;
        }
        boolean updateAvailable = manifest.modBuild > CURRENT_MOD_BUILD
                && manifest.versionCode > installedVersion;
        if (required && !updateAvailable) {
            showUnavailable(activity, generation,
                    "A required update policy is active, but its installable artifact is not newer.");
            return true;
        }
        if (!updateAvailable) return false;
        if (!required) {
            try {
                if (UpdateStore.dismissedRevision(activity) == manifest.revision) return false;
            } catch (Throwable corrupt) {
                // A corrupt optional dismissal is not authority to lock the app or suppress UI.
            }
        }
        showUpdateDialog(activity, generation, manifest, required);
        return true;
    }

    private static void showUpdateDialog(
            final Activity activity, final long generation,
            final UpdateManifest manifest, final boolean required) {
        if (!isCurrentOwner(activity, generation)) return;
        StringBuilder message = new StringBuilder();
        message.append(required ? "This update is required to continue." : "An update is available.")
                .append("\n\nVersion ").append(manifest.versionName);
        if (manifest.notes.length() > 0) {
            String displayNotes = displayNotes(manifest.notes);
            message.append("\n\n").append(displayNotes);
        }
        AlertDialog.Builder builder = new AlertDialog.Builder(activity)
                .setTitle(required ? "Required update" : "Update available")
                .setMessage(message.toString())
                .setPositiveButton("Update", null);
        if (!required) {
            builder.setNegativeButton("Later", new DialogInterface.OnClickListener() {
                @Override public void onClick(DialogInterface ignored, int which) {
                    if (!UpdateStore.dismiss(activity, manifest.revision)) {
                        // Failure to remember an optional choice may re-prompt later, but is not
                        // authority for a non-dismissible application lock.
                    }
                    runFallback(activity, generation);
                }
            });
        }
        final AlertDialog shown = builder.create();
        shown.setCancelable(!required);
        shown.setCanceledOnTouchOutside(false);
        if (!required) {
            shown.setOnCancelListener(new DialogInterface.OnCancelListener() {
                @Override public void onCancel(DialogInterface ignored) {
                    runFallback(activity, generation);
                }
            });
        }
        shown.setOnShowListener(new DialogInterface.OnShowListener() {
            @Override public void onShow(DialogInterface ignored) {
                Button update = shown.getButton(AlertDialog.BUTTON_POSITIVE);
                update.setOnClickListener(new View.OnClickListener() {
                    @Override public void onClick(View view) {
                        beginInstall(activity, generation, manifest, shown);
                    }
                });
            }
        });
        synchronized (LOCK) {
            if (!isCurrentOwner(activity, generation)) return;
            if (dialog != null) dialog.dismiss();
            dialog = shown;
            dialogOwnerGeneration = generation;
            dialogRequired = required;
        }
        shown.show();
    }

    private static void beginInstall(
            final Activity activity, final long generation,
            final UpdateManifest manifest, final AlertDialog shown) {
        if (!isCurrentOwner(activity, generation)) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                && !activity.getPackageManager().canRequestPackageInstalls()) {
            try {
                Intent settings = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:" + activity.getPackageName()));
                activity.startActivity(settings);
                shown.setMessage("Allow installs from this app, then return to continue the verified update.");
            } catch (Throwable unavailable) {
                shown.setMessage("Android's install-source settings could not be opened.");
            }
            return;
        }
        final long taskToken;
        synchronized (LOCK) {
            if (downloadInFlight) {
                if (downloadManifest != null && manifest.sameBinary(downloadManifest)) {
                    downloadAuthorizedActivity = new WeakReference<Activity>(activity);
                    downloadAuthorizedGeneration = generation;
                    downloadAuthorizedDialog = shown;
                    shown.setMessage("Downloading and verifying the update…");
                    shown.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(false);
                } else {
                    shown.setMessage(
                            "A previous update download is finishing. Try Update again shortly.");
                    shown.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(true);
                }
                return;
            }
            downloadInFlight = true;
            downloadToken++;
            taskToken = downloadToken;
            downloadManifest = manifest;
            downloadAuthorizedActivity = new WeakReference<Activity>(activity);
            downloadAuthorizedGeneration = generation;
            downloadAuthorizedDialog = shown;
        }
        shown.setMessage("Downloading and verifying the update…");
        shown.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(false);
        try {
            Thread worker = new Thread(new Runnable() {
            @Override public void run() {
                File apk = null;
                try {
                    apk = obtainVerifiedApk(activity.getApplicationContext(), manifest);
                } catch (Throwable ignored) {
                    apk = null;
                }
                final File completed = apk;
                boolean accepted = false;
                try {
                    accepted = MAIN.post(new Runnable() {
                        @Override public void run() {
                            finishDownload(taskToken, manifest, completed);
                        }
                    });
                } catch (Throwable rejected) {
                    accepted = false;
                }
                if (!accepted) clearDownloadTask(taskToken);
            }
            }, "ThreadsModUpdateDownload");
            worker.start();
        } catch (Throwable rejected) {
            clearDownloadTask(taskToken);
            if (isCurrentOwner(activity, generation)) {
                synchronized (LOCK) {
                    if (dialog != shown || !shown.isShowing()) return;
                }
                shown.setMessage("The update download could not start. Try again.");
                shown.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(true);
            }
        }
    }

    private static void finishDownload(
            long taskToken, final UpdateManifest taskManifest, final File completed) {
        Activity activity;
        long generation;
        AlertDialog shown;
        synchronized (LOCK) {
            if (!downloadInFlight || downloadToken != taskToken) return;
            activity = downloadAuthorizedActivity.get();
            generation = downloadAuthorizedGeneration;
            shown = downloadAuthorizedDialog;
            clearDownloadTaskLocked();
        }
        if (!isCurrentOwner(activity, generation) || shown == null) return;
        synchronized (LOCK) {
            if (dialog != shown || !shown.isShowing()) return;
        }
        if (completed == null) {
            shown.setMessage("The update could not be downloaded or verified. Try again.");
            shown.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(true);
            return;
        }
        final Activity installerActivity = activity;
        int installResult;
        try {
            installResult = UpdateStore.runIfCurrentBinary(
                    activity, System.currentTimeMillis(), taskManifest,
                    new UpdateStore.CurrentBinaryAction() {
                        @Override public boolean run() {
                            return launchInstaller(installerActivity, completed);
                        }
                    });
        } catch (Throwable invalidLatestPolicy) {
            shown.setMessage("The latest update policy cannot be verified. Try again.");
            shown.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(true);
            return;
        }
        if (installResult == UpdateStore.CURRENT_BINARY_ACTION_SUCCEEDED) return;
        if (installResult == UpdateStore.CURRENT_BINARY_MISMATCH) {
            UpdateManifest latest;
            try {
                latest = UpdateStore.load(activity, System.currentTimeMillis());
            } catch (Throwable invalidLatestPolicy) {
                latest = null;
            }
            if (latest != null && presentIfApplicable(activity, generation, latest)) return;
            shown.setMessage("The update policy changed. Try Update again.");
            shown.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(true);
            return;
        }
        if (installResult == UpdateStore.CURRENT_BINARY_ACTION_FAILED) {
            shown.setMessage("Android's package installer could not be opened.");
            shown.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(true);
        }
    }

    private static void clearDownloadTask(long taskToken) {
        synchronized (LOCK) {
            if (downloadInFlight && downloadToken == taskToken) clearDownloadTaskLocked();
        }
    }

    private static void clearDownloadTaskLocked() {
        downloadInFlight = false;
        downloadManifest = null;
        downloadAuthorizedActivity = new WeakReference<Activity>(null);
        downloadAuthorizedGeneration = 0L;
        downloadAuthorizedDialog = null;
    }

    private static File obtainVerifiedApk(Context context, UpdateManifest manifest)
            throws Exception {
        File shared = new File(context.getCacheDir(), "shared");
        File directory = new File(shared, "updates");
        if (!directory.exists() && !directory.mkdirs()) {
            throw new IllegalStateException("update cache is unavailable");
        }
        long operationDeadline = deadlineAfter(DOWNLOAD_OPERATION_TIMEOUT_MS);
        File completed = new File(directory, CACHE_APK_NAME);
        if (completed.isFile()) {
            boolean cachedValid = verifyFile(context, completed, manifest);
            if (isExpired(operationDeadline)) {
                throw new IllegalStateException("update download operation expired");
            }
            if (cachedValid) return completed;
        }
        if (completed.exists() && !completed.delete()) {
            throw new IllegalStateException("stale update cannot be removed");
        }
        File partial = new File(directory, CACHE_PART_NAME);
        for (URL initial : manifest.downloadUrls) {
            if (isExpired(operationDeadline)) break;
            if (partial.exists() && !partial.delete()) continue;
            try {
                long attemptDeadline = Math.min(
                        operationDeadline, deadlineAfter(DOWNLOAD_ATTEMPT_TIMEOUT_MS));
                downloadOne(initial, partial, manifest, attemptDeadline);
                if (isExpired(operationDeadline)) {
                    throw new IllegalStateException("update download operation expired");
                }
                if (!verifyFile(context, partial, manifest)) {
                    throw new SecurityException("update verification failed");
                }
                if (isExpired(operationDeadline)) {
                    throw new IllegalStateException("update download operation expired");
                }
                if (!partial.renameTo(completed)) throw new IllegalStateException("update commit failed");
                return completed;
            } catch (Throwable ignoredMirror) {
                if (partial.exists()) partial.delete();
            }
        }
        throw new IllegalStateException("all update artifact mirrors failed");
    }

    private static void downloadOne(
            URL initial, File output, UpdateManifest manifest, long attemptDeadline)
            throws Exception {
        URL current = initial;
        for (int hop = 0; hop <= 3; hop++) {
            HttpsURLConnection connection = null;
            Timer deadlineDisconnect = null;
            try {
                connection = openIsolated(current);
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(timeoutBefore(attemptDeadline, 15000));
                connection.setReadTimeout(timeoutBefore(attemptDeadline, 30000));
                connection.setUseCaches(false);
                connection.setRequestMethod("GET");
                connection.setRequestProperty("User-Agent", USER_AGENT);
                connection.setRequestProperty(
                        "Accept", "application/vnd.android.package-archive");
                connection.setRequestProperty("Accept-Encoding", "identity");
                deadlineDisconnect = disconnectAtDeadline(connection, attemptDeadline);
                requireIsolatedHttp();
                connection.setReadTimeout(timeoutBefore(attemptDeadline, 30000));
                int status = connection.getResponseCode();
                if (isAllowedRedirect(status)) {
                    if (hop == 3) throw new SecurityException("update redirect limit exceeded");
                    current = UpdateEndpoints.validateRedirect(
                            current, connection.getHeaderField("Location"), manifest.apkName, hop + 1);
                    continue;
                }
                if (status != HttpsURLConnection.HTTP_OK) {
                    throw new IllegalStateException("update download failed");
                }
                long declared = connection.getContentLengthLong();
                if (declared >= 0L && declared != manifest.apkSize) {
                    throw new SecurityException("update download size differs");
                }
                requireIsolatedHttp();
                try (InputStream input = connection.getInputStream();
                     FileOutputStream file = new FileOutputStream(output)) {
                    byte[] buffer = new byte[32768];
                    long total = 0L;
                    while (true) {
                        connection.setReadTimeout(timeoutBefore(attemptDeadline, 30000));
                        int read = input.read(buffer);
                        if (read < 0) break;
                        if (isExpired(attemptDeadline)) {
                            throw new IllegalStateException("update download attempt expired");
                        }
                        total += read;
                        if (total > manifest.apkSize || total > UpdateManifest.MAX_APK_BYTES) {
                            throw new SecurityException("update download exceeds bound");
                        }
                        file.write(buffer, 0, read);
                    }
                    if (isExpired(attemptDeadline)) {
                        throw new IllegalStateException("update download attempt expired");
                    }
                    file.getFD().sync();
                    if (isExpired(attemptDeadline)) {
                        throw new IllegalStateException("update download attempt expired");
                    }
                    if (total != manifest.apkSize) throw new SecurityException("update download is truncated");
                }
                return;
            } finally {
                if (deadlineDisconnect != null) deadlineDisconnect.cancel();
                if (connection != null) connection.disconnect();
            }
        }
        throw new SecurityException("update redirect state is invalid");
    }

    private static boolean verifyFile(
            Context context, File apk, UpdateManifest manifest) throws Exception {
        if (!apk.isFile() || apk.length() != manifest.apkSize
                || !manifest.apkSha256.equals(sha256(apk))) return false;
        PackageManager manager = context.getPackageManager();
        PackageInfo archive = manager.getPackageArchiveInfo(
                apk.getAbsolutePath(), PackageManager.GET_SIGNING_CERTIFICATES);
        PackageInfo current = manager.getPackageInfo(
                UpdateManifest.APPLICATION_ID, PackageManager.GET_SIGNING_CERTIFICATES);
        if (archive == null || !UpdateManifest.APPLICATION_ID.equals(archive.packageName)
                || archive.getLongVersionCode() != manifest.versionCode
                || !manifest.versionName.equals(archive.versionName)
                || archive.getLongVersionCode() <= current.getLongVersionCode()) return false;
        String archiveSigner = onlySignerSha256(archive);
        String currentSigner = onlySignerSha256(current);
        return manifest.signerSha256.equals(UpdateManifest.REQUIRED_SIGNER_SHA256)
                && manifest.signerSha256.equals(archiveSigner)
                && manifest.signerSha256.equals(currentSigner);
    }

    private static String onlySignerSha256(PackageInfo info) throws Exception {
        if (info == null || info.signingInfo == null) return "";
        Signature[] signers = info.signingInfo.getApkContentsSigners();
        if (signers == null || signers.length != 1) return "";
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(signers[0].toByteArray());
        return hex(digest);
    }

    private static boolean launchInstaller(Activity activity, File apk) {
        try {
            Class<?> provider = Class.forName("androidx.core.content.FileProvider");
            Method method = provider.getMethod(
                    "getUriForFile", Context.class, String.class, File.class);
            Uri uri = (Uri) method.invoke(
                    null, activity, FILE_PROVIDER_AUTHORITY, apk);
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(uri, "application/vnd.android.package-archive");
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            activity.startActivity(intent);
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static byte[] readBounded(
            HttpsURLConnection connection, InputStream input, int maximum,
            long deadline, int maximumReadTimeoutMs) throws Exception {
        try (InputStream bounded = input; ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int total = 0;
            while (true) {
                connection.setReadTimeout(timeoutBefore(deadline, maximumReadTimeoutMs));
                int read = bounded.read(buffer);
                if (read < 0) break;
                if (isExpired(deadline)) {
                    throw new IllegalStateException("update metadata attempt expired");
                }
                total += read;
                if (total > maximum) throw new SecurityException("update metadata exceeds bound");
                output.write(buffer, 0, read);
            }
            return output.toByteArray();
        }
    }

    private static boolean isAllowedRedirect(int status) {
        return status == HttpsURLConnection.HTTP_MOVED_PERM
                || status == HttpsURLConnection.HTTP_MOVED_TEMP
                || status == HttpsURLConnection.HTTP_SEE_OTHER
                || status == 307 || status == 308;
    }

    private static long deadlineAfter(long durationMs) {
        long now = SystemClock.elapsedRealtime();
        return now > Long.MAX_VALUE - durationMs ? Long.MAX_VALUE : now + durationMs;
    }

    private static boolean isExpired(long deadline) {
        return SystemClock.elapsedRealtime() >= deadline;
    }

    private static int timeoutBefore(long deadline, int maximumMs) {
        long remaining = deadline - SystemClock.elapsedRealtime();
        if (remaining <= 0L) throw new IllegalStateException("update network deadline expired");
        return (int) Math.max(1L, Math.min((long) maximumMs, remaining));
    }

    private static Timer disconnectAtDeadline(
            final HttpsURLConnection connection, long deadline) {
        long remaining = deadline - SystemClock.elapsedRealtime();
        if (remaining <= 0L) throw new IllegalStateException("update network deadline expired");
        Timer timer = new Timer("ThreadsModUpdateDeadline", true);
        try {
            timer.schedule(new TimerTask() {
                @Override public void run() {
                    connection.disconnect();
                }
            }, remaining);
            return timer;
        } catch (RuntimeException rejected) {
            timer.cancel();
            throw rejected;
        }
    }

    private static void requireIsolatedHttp() {
        if (CookieHandler.getDefault() != null) {
            throw new SecurityException("update HTTP client is not cookie-isolated");
        }
    }

    private static HttpsURLConnection openIsolated(URL url) throws Exception {
        synchronized (CookieHandler.class) {
            requireIsolatedHttp();
            return (HttpsURLConnection) url.openConnection();
        }
    }

    private static String sha256(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[32768];
            for (int read; (read = input.read(buffer)) >= 0; ) digest.update(buffer, 0, read);
        }
        return hex(digest.digest());
    }

    private static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) out.append(String.format(java.util.Locale.US, "%02x", value & 0xff));
        return out.toString();
    }

    private static String displayNotes(String notes) {
        if (notes.length() <= 600) return notes;
        int end = 599;
        if (end > 0 && Character.isHighSurrogate(notes.charAt(end - 1))) end--;
        return notes.substring(0, end) + "…";
    }

    private static void showUnavailable(Activity activity, long generation, String message) {
        if (!isCurrentOwner(activity, generation)) return;
        AlertDialog shown = new AlertDialog.Builder(activity)
                .setTitle("Update unavailable")
                .setMessage(message)
                .setPositiveButton("Retry", new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface ignored, int which) {
                        onResume(activity, fallback);
                    }
                }).create();
        shown.setCancelable(false);
        shown.setCanceledOnTouchOutside(false);
        synchronized (LOCK) {
            if (dialog != null) dialog.dismiss();
            dialog = shown;
            dialogOwnerGeneration = generation;
            dialogRequired = true;
        }
        shown.show();
    }

    private static void showRetainedRequiredUnavailable(
            Activity activity, long generation) {
        showUnavailable(activity, generation,
                "A required update remains active. Connect and retry to verify the latest update before continuing.");
    }

    private static void runFallback(Activity activity, long generation) {
        Runnable action;
        synchronized (LOCK) {
            if (!isCurrentOwner(activity, generation)) return;
            if (dialogRequired && dialogOwnerGeneration == generation
                    && dialog != null && dialog.isShowing()) return;
            action = fallback;
            fallback = null;
        }
        if (action != null) action.run();
    }

    private static boolean isCurrentOwner(Activity activity, long generation) {
        synchronized (LOCK) {
            return owner.get() == activity && ownerGeneration == generation && isUsable(activity);
        }
    }

    private static boolean isUsable(Activity activity) {
        return activity != null && !activity.isFinishing() && !activity.isDestroyed();
    }
}
