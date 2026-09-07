package com.threadsmod;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import threadsmod.autoblock.AutoBlockSync;
import threadsmod.autoblock.BlockLimits;
import threadsmod.autoblock.BlockLimitsStore;
import threadsmod.autoblock.ModStateStore;
import threadsmod.proxy.ProxyController;
import threadsmod.reporting.ReportClient;
import threadsmod.reporting.ReportStore;

/** Resource-free settings surface for Clone Blocker inside the cloned APK. */
public final class CloneBlockerSettingsActivity extends Activity {
    private static final long STATUS_POLL_INTERVAL_MS = 1000L;
    private static final String STATUS_POLL_UNAVAILABLE =
            "Unavailable: live block-list status refresh stopped. Reopen this page.";

    private TextView statusValue;
    private Button syncButton;
    private EditText passiveMinDelay;
    private EditText passiveMaxDelay;
    private TextView passiveDelayStateValue;
    private TextView reportSummary;
    private TextView reportState;
    private TextView proxyStatus;
    private boolean contentReady;
    private boolean statusPolling;
    private boolean statusPollingUnavailable;
    private final Handler statusHandler = new Handler(Looper.getMainLooper());
    private final Runnable statusPoll = new Runnable() {
        @Override
        public void run() {
            if (!statusPolling || !contentReady) {
                return;
            }
            refreshRuntimeState();
            if (statusPolling && !statusHandler.postDelayed(this, STATUS_POLL_INTERVAL_MS)) {
                showStatusPollingUnavailable();
            }
        }
    };

    /** Opens this private surface from the currently resumed cloned Threads activity. */
    public static boolean openFromForeground() {
        Activity activity = AutoBlockSync.getForegroundActivity();
        if (activity == null || activity.isFinishing() || activity.isDestroyed()) {
            return false;
        }
        try {
            activity.startActivity(new Intent(activity, CloneBlockerSettingsActivity.class));
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        setTheme(android.R.style.Theme_DeviceDefault_NoActionBar);
        super.onCreate(savedInstanceState);
        setTitle("Clone Blocker settings");
        buildContent();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (!contentReady) {
            return;
        }
        refreshPassiveDelayFields();
        refreshRuntimeState();
        refreshReportState();
        refreshProxyState();
        startStatusPolling();
    }

    @Override
    protected void onPause() {
        stopStatusPolling();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        stopStatusPolling();
        super.onDestroy();
    }

    private void buildContent() {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(CloneBlockerUi.background(this));

        LinearLayout root = CloneBlockerUi.column(this);
        int horizontal = CloneBlockerUi.dp(this, 20);
        root.setPadding(horizontal, CloneBlockerUi.dp(this, 24),
                horizontal, CloneBlockerUi.dp(this, 36));
        scroll.addView(root, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        // Attach a visible shell before reading persisted state or constructing dynamic cards.
        root.addView(CloneBlockerUi.title(this, "Settings"));
        TextView loadingShell = CloneBlockerUi.body(this, "Loading local settings…");
        CloneBlockerUi.addTopSpace(this, loadingShell, 8);
        root.addView(loadingShell);
        setContentView(scroll);
        final boolean initialAlsoBlockEnabled;
        try {
            initialAlsoBlockEnabled = ModStateStore.isAlsoBlockProfileEnabled(this);
        } catch (RuntimeException invalidLocalState) {
            showFailClosedShell(root);
            return;
        }
        root.removeAllViews();

        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(android.view.Gravity.CENTER_VERTICAL);
        TextView title = CloneBlockerUi.title(this, "Settings");
        header.addView(title, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button activity = CloneBlockerUi.button(this, "Activity");
        activity.setContentDescription("Open Clone Blocker activity");
        activity.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                startActivity(new Intent(
                        CloneBlockerSettingsActivity.this,
                        CloneBlockerActivity.class));
            }
        });
        header.addView(activity, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        root.addView(header);
        TextView intro = CloneBlockerUi.secondary(
                this,
                "Control passive on-screen blocking and the inline Block action. Settings stay on this device.");
        CloneBlockerUi.addTopSpace(this, intro, 6);
        root.addView(intro);

        LinearLayout statusCard = CloneBlockerUi.card(this);
        statusCard.addView(CloneBlockerUi.sectionTitle(this, "Current status"));
        statusValue = CloneBlockerUi.body(this, "");
        CloneBlockerUi.addTopSpace(this, statusValue, 8);
        statusCard.addView(statusValue);
        syncButton = CloneBlockerUi.button(this, "Sync now");
        syncButton.setContentDescription("Synchronize the signed block list now");
        CloneBlockerUi.addTopSpace(this, syncButton, 12);
        syncButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                AutoBlockSync.enableAndSync(CloneBlockerSettingsActivity.this);
                Toast.makeText(CloneBlockerSettingsActivity.this,
                        "Sync requested. Return to the Threads feed to continue.",
                        Toast.LENGTH_SHORT).show();
                refreshRuntimeState();
            }
        });
        statusCard.addView(syncButton);
        root.addView(statusCard);

        LinearLayout automaticCard = CloneBlockerUi.card(this);
        automaticCard.addView(CloneBlockerUi.sectionTitle(this, "Passive blocking"));
        TextView automaticSummary = CloneBlockerUi.secondary(
                this,
                "Always on. Refreshes the signed index every 10 minutes in the foreground, then blocks only listed profiles whose post or reply action row becomes visible.");
        CloneBlockerUi.addTopSpace(this, automaticSummary, 8);
        automaticCard.addView(automaticSummary);
        root.addView(automaticCard);

        LinearLayout proxyCard = CloneBlockerUi.card(this);
        proxyCard.addView(CloneBlockerUi.sectionTitle(this, "SOCKS5 proxy"));
        proxyStatus = CloneBlockerUi.body(this, "Loading…");
        CloneBlockerUi.addTopSpace(this, proxyStatus, 8);
        proxyCard.addView(proxyStatus);
        TextView proxySummary = CloneBlockerUi.secondary(
                this,
                "Route only this cloned Threads app through SOCKS5, with ordered numeric IP/CIDR direct exceptions.");
        CloneBlockerUi.addTopSpace(this, proxySummary, 6);
        proxyCard.addView(proxySummary);
        Button configureProxy = CloneBlockerUi.button(this, "Configure proxy");
        configureProxy.setContentDescription("Open SOCKS5 proxy settings");
        CloneBlockerUi.addTopSpace(this, configureProxy, 10);
        configureProxy.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                startActivity(new Intent(
                        CloneBlockerSettingsActivity.this,
                        ProxySettingsActivity.class));
            }
        });
        proxyCard.addView(configureProxy);
        root.addView(proxyCard);

        LinearLayout inlineCard = CloneBlockerUi.card(this);
        inlineCard.addView(CloneBlockerUi.sectionTitle(this, "Inline action"));
        final Switch alsoBlock = settingSwitch(
                "Also block this profile",
                "Sets the default for the checkbox in the Block and report modal. The modal always opens so you can confirm the report reason and post excerpt.",
                initialAlsoBlockEnabled,
                inlineCard);
        alsoBlock.setOnCheckedChangeListener(new CompoundButton.OnCheckedChangeListener() {
            @Override
            public void onCheckedChanged(CompoundButton buttonView, boolean checked) {
                ModStateStore.setAlsoBlockProfileEnabled(
                        CloneBlockerSettingsActivity.this, checked);
            }
        });
        root.addView(inlineCard);

        LinearLayout passiveDelayCard = CloneBlockerUi.card(this);
        passiveDelayCard.addView(CloneBlockerUi.sectionTitle(this, "Passive delay"));
        TextView passiveDelayDescription = CloneBlockerUi.body(
                this,
                "Passive blocking waits a random delay between eligible visible-profile "
                        + "attempts. Manual inline Block is not paced by these values.");
        CloneBlockerUi.addTopSpace(this, passiveDelayDescription, 8);
        passiveDelayCard.addView(passiveDelayDescription);
        passiveDelayStateValue = CloneBlockerUi.secondary(this, "");
        CloneBlockerUi.addTopSpace(this, passiveDelayStateValue, 8);
        passiveDelayCard.addView(passiveDelayStateValue);
        passiveMinDelay = numericSetting(
                "Passive minimum delay (seconds)", "2–60, in whole seconds",
                passiveDelayCard);
        passiveMaxDelay = numericSetting(
                "Passive maximum delay (seconds)", "3–60, in whole seconds",
                passiveDelayCard);

        LinearLayout passiveDelayButtons = new LinearLayout(this);
        passiveDelayButtons.setOrientation(LinearLayout.HORIZONTAL);
        CloneBlockerUi.addTopSpace(this, passiveDelayButtons, 12);
        Button savePassiveDelay = CloneBlockerUi.button(this, "Save delay");
        savePassiveDelay.setContentDescription("Validate and save the passive delay pair");
        savePassiveDelay.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                savePassiveDelay();
            }
        });
        passiveDelayButtons.addView(savePassiveDelay, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button restorePassiveDelay = CloneBlockerUi.button(this, "Use 4–10 seconds");
        restorePassiveDelay.setContentDescription("Restore the default passive delay pair");
        restorePassiveDelay.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                if (BlockLimitsStore.save(
                        CloneBlockerSettingsActivity.this, BlockLimits.defaults())) {
                    refreshPassiveDelayFields();
                    AutoBlockSync.onLimitsChanged(CloneBlockerSettingsActivity.this);
                    Toast.makeText(CloneBlockerSettingsActivity.this,
                            "Default passive delay restored.", Toast.LENGTH_SHORT).show();
                } else {
                    Toast.makeText(CloneBlockerSettingsActivity.this,
                            "Could not persist the passive delay.", Toast.LENGTH_LONG).show();
                }
            }
        });
        LinearLayout.LayoutParams restoreParams = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        restoreParams.setMarginStart(CloneBlockerUi.dp(this, 8));
        passiveDelayButtons.addView(restorePassiveDelay, restoreParams);
        passiveDelayCard.addView(passiveDelayButtons);

        TextView scheduling = CloneBlockerUi.secondary(
                this,
                "The selected random delay is persisted before each passive attempt. "
                        + "Manual inline Block remains unpaced.");
        CloneBlockerUi.addTopSpace(this, scheduling, 10);
        passiveDelayCard.addView(scheduling);
        root.addView(passiveDelayCard);

        LinearLayout reportCard = CloneBlockerUi.card(this);
        reportCard.addView(CloneBlockerUi.sectionTitle(this, "Reports"));
        reportSummary = CloneBlockerUi.body(this, "Loading viewer-scoped report state…");
        CloneBlockerUi.addTopSpace(this, reportSummary, 8);
        reportCard.addView(reportSummary);
        reportState = CloneBlockerUi.secondary(this, "");
        CloneBlockerUi.addTopSpace(this, reportState, 6);
        reportCard.addView(reportState);
        TextView reportPrivacy = CloneBlockerUi.secondary(
                this,
                "A report is created only when you tap Block or Report in the combined Block and report modal. The queued payload includes the profile username, numeric profile ID, canonical Threads post permalink as targetUrl and the sole evidence entry, post excerpt capped at 280 UTF-16 units, selected reason, stable pseudonym, and language/time zone, and is stored before any network attempt. The relay/backend stores the full connection IP address, full HTTP User-Agent, and network-derived city/country on the report; moderators/project operators can view and correlate them, server backups include them, and server reports have no automatic expiry before administrative deletion. The JSON never contains the raw viewer ID, Threads cookies, session, or access token. Pending payloads can remain viewer-scoped indefinitely and retry only while the main Threads UI is foregrounded. Local terminal history keeps at most 500 records with no time-based expiry. Cancellation can race active delivery and cannot retract a server-accepted copy. Separately, this build sends one activation ping per installed build to the same relay host at /v1/installs. It contains only an install identifier derived from a local random secret with no account input, the clone package name, version name and code, mod build, Android SDK level, device manufacturer, model, primary CPU ABI, language tag and time zone, plus the send time. It is never linked to your Threads account or to a report, and the relay additionally sees the connection IP address and User-Agent of that request.");
        CloneBlockerUi.addTopSpace(this, reportPrivacy, 10);
        reportCard.addView(reportPrivacy);
        Button reportActivity = CloneBlockerUi.button(this, "Open report outbox");
        CloneBlockerUi.addTopSpace(this, reportActivity, 10);
        reportActivity.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                startActivity(new Intent(
                        CloneBlockerSettingsActivity.this,
                        CloneBlockerActivity.class));
            }
        });
        reportCard.addView(reportActivity);
        root.addView(reportCard);

        LinearLayout privacyCard = CloneBlockerUi.card(this);
        privacyCard.addView(CloneBlockerUi.sectionTitle(this, "Mirror-only list access"));
        TextView privacy = CloneBlockerUi.body(
                this,
                "Signed blocklists are read only from the reviewed HTTPS mirror allowlist. "
                        + "Redirects are refused, payload size is capped, and Ed25519 verification is required.");
        CloneBlockerUi.addTopSpace(this, privacy, 8);
        privacyCard.addView(privacy);
        TextView noCredentials = CloneBlockerUi.secondary(
                this,
                "The list request receives no Threads cookie, token, session object, or account ID. Blocks use Threads' own signed-in native action.");
        CloneBlockerUi.addTopSpace(this, noCredentials, 10);
        privacyCard.addView(noCredentials);
        root.addView(privacyCard);

        try {
            refreshPassiveDelayFields();
            refreshRuntimeState();
            refreshReportState();
            refreshProxyState();
            contentReady = true;
        } catch (RuntimeException invalidLocalState) {
            showFailClosedShell(root);
        }
    }

    private void showFailClosedShell(LinearLayout root) {
        contentReady = false;
        root.removeAllViews();
        root.addView(CloneBlockerUi.title(this, "Settings"));
        LinearLayout review = CloneBlockerUi.card(this);
        review.addView(CloneBlockerUi.sectionTitle(this, "Settings data needs review"));
        TextView message = CloneBlockerUi.body(
                this,
                "Local mod settings could not be displayed and stored data was not reset. Blocking stays paused. An active Android VPN stays fail-closed; without one, direct traffic may continue.");
        CloneBlockerUi.addTopSpace(this, message, 8);
        message.setTextColor(CloneBlockerUi.danger(this));
        review.addView(message);
        root.addView(review);
    }

    private EditText numericSetting(
            String title,
            String range,
            LinearLayout parent) {
        TextView label = CloneBlockerUi.body(this, title);
        CloneBlockerUi.addTopSpace(this, label, 10);
        parent.addView(label);
        EditText value = new EditText(this);
        value.setSingleLine(true);
        value.setSelectAllOnFocus(true);
        value.setTextColor(CloneBlockerUi.foreground(this));
        value.setHintTextColor(CloneBlockerUi.secondary(this));
        value.setInputType(InputType.TYPE_CLASS_NUMBER);
        value.setContentDescription(title + "; " + range);
        parent.addView(value, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        parent.addView(CloneBlockerUi.secondary(this, range));
        return value;
    }

    private void savePassiveDelay() {
        try {
            BlockLimits limits = BlockLimits.checked(
                    parseWholeSeconds(passiveMinDelay),
                    parseWholeSeconds(passiveMaxDelay));
            if (!BlockLimitsStore.save(this, limits)) {
                Toast.makeText(this,
                        "Could not confirm passive-delay persistence; passive blocking is "
                                + "paused until a complete valid pair is saved.",
                        Toast.LENGTH_LONG).show();
                return;
            }
            refreshPassiveDelayFields();
            AutoBlockSync.onLimitsChanged(this);
            Toast.makeText(this, "Passive delay saved.", Toast.LENGTH_SHORT).show();
        } catch (IllegalArgumentException invalid) {
            String message = invalid.getMessage();
            Toast.makeText(this,
                    message == null ? "Check both passive delay values; nothing changed." : message,
                    Toast.LENGTH_LONG).show();
        }
    }

    private static int parseWholeSeconds(EditText input) {
        String raw = input == null ? "" : input.getText().toString().trim();
        if (raw.length() == 0) {
            throw new IllegalArgumentException("Both passive delays need a value.");
        }
        final int seconds;
        try {
            seconds = Integer.parseInt(raw);
        } catch (NumberFormatException invalid) {
            throw new IllegalArgumentException("Passive delays must be whole seconds.");
        }
        try {
            return Math.multiplyExact(seconds, 1000);
        } catch (ArithmeticException invalid) {
            throw new IllegalArgumentException("Passive delay value is not valid.");
        }
    }

    private void refreshPassiveDelayFields() {
        if (passiveMinDelay == null) {
            return;
        }
        BlockLimits limits = BlockLimitsStore.load(this);
        passiveDelayStateValue.setText(BlockLimitsStore.isValid(this)
                ? "Stored passive delay: validated."
                : "Stored passive delay needs review. Passive blocking is paused until you "
                        + "save one complete valid pair or restore 4–10 seconds. Manual inline "
                        + "Block remains unpaced.");
        passiveMinDelay.setText(formatSeconds(limits.passiveMinDelayMs()));
        passiveMaxDelay.setText(formatSeconds(limits.passiveMaxDelayMs()));
    }

    private static String formatSeconds(int milliseconds) {
        if (milliseconds % 1000 == 0) {
            return String.valueOf(milliseconds / 1000);
        }
        return String.valueOf(milliseconds / 1000d);
    }

    private Switch settingSwitch(
            String title,
            String summary,
            boolean checked,
            LinearLayout parent) {
        Switch control = new Switch(this);
        control.setText(title);
        control.setTextSize(16);
        control.setTextColor(CloneBlockerUi.foreground(this));
        control.setChecked(checked);
        control.setMinHeight(CloneBlockerUi.dp(this, 48));
        CloneBlockerUi.addTopSpace(this, control, 8);
        parent.addView(control, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        TextView detail = CloneBlockerUi.secondary(this, summary);
        detail.setPadding(0, 0, 0, CloneBlockerUi.dp(this, 6));
        parent.addView(detail);
        return control;
    }

    private void refreshRuntimeState() {
        if (statusValue == null) {
            return;
        }
        try {
            String status = "Enabled\n"
                    + AutoBlockSync.getStatus(this)
                    + "\n\n" + AutoBlockSync.getListStatus(this);
            statusValue.setText(statusPollingUnavailable
                    ? status + "\n" + STATUS_POLL_UNAVAILABLE : status);
            statusValue.setTextColor(statusPollingUnavailable
                    ? CloneBlockerUi.danger(this) : CloneBlockerUi.foreground(this));
            if (syncButton != null) {
                syncButton.setText("Sync now");
                syncButton.setEnabled(
                        !AutoBlockSync.isRunning() && !AutoBlockSync.isRefreshingList());
            }
        } catch (RuntimeException unavailable) {
            showStatusPollingUnavailable();
        }
    }

    private void startStatusPolling() {
        statusHandler.removeCallbacks(statusPoll);
        statusPolling = contentReady;
        statusPollingUnavailable = false;
        if (!statusPolling) {
            return;
        }
        refreshRuntimeState();
        if (statusPolling
                && !statusHandler.postDelayed(statusPoll, STATUS_POLL_INTERVAL_MS)) {
            showStatusPollingUnavailable();
        }
    }

    private void stopStatusPolling() {
        statusPolling = false;
        statusHandler.removeCallbacks(statusPoll);
    }

    private void showStatusPollingUnavailable() {
        statusPolling = false;
        statusPollingUnavailable = true;
        statusHandler.removeCallbacks(statusPoll);
        if (statusValue != null) {
            CharSequence current = statusValue.getText();
            String prefix = current == null ? "" : current.toString();
            if (!prefix.contains(STATUS_POLL_UNAVAILABLE)) {
                statusValue.setText(prefix.length() == 0
                        ? STATUS_POLL_UNAVAILABLE
                        : prefix + "\n" + STATUS_POLL_UNAVAILABLE);
            }
            statusValue.setTextColor(CloneBlockerUi.danger(this));
        }
    }

    private void refreshProxyState() {
        if (proxyStatus == null) {
            return;
        }
        String status = ProxyController.status(this);
        proxyStatus.setText(status);
        proxyStatus.setTextColor(status.startsWith("Paused")
                || status.startsWith("Unprotected")
                || status.startsWith("Unavailable")
                ? CloneBlockerUi.danger(this)
                : CloneBlockerUi.foreground(this));
    }

    private void refreshReportState() {
        if (reportSummary == null || reportState == null) {
            return;
        }
        final String viewerId = ModStateStore.getActiveViewer(this);
        reportSummary.setText(viewerId.length() == 0
                ? "Open a signed-in Threads feed to select a report scope."
                : "Loading viewer-scoped report state…");
        reportState.setText("");
        ReportClient.getLocalStatusAsync(
                this,
                viewerId,
                new ReportClient.LocalStatusCallback() {
                    @Override
                    public void onStatus(ReportStore.Snapshot snapshot) {
                        if (isFinishing() || isDestroyed()
                                || !viewerId.equals(ModStateStore.getActiveViewer(
                                CloneBlockerSettingsActivity.this))) {
                            return;
                        }
                        reportSummary.setText(
                                "Pending: " + snapshot.pendingCount
                                        + "  ·  Sent (retained): " + snapshot.sentCount
                                        + "  ·  Rejected: " + snapshot.rejectedCount
                                        + "  ·  Unconfirmed: " + snapshot.gaveUpCount);
                        String state;
                        if (snapshot.needsReview) {
                            state = "Local report storage needs review (outbox: "
                                    + snapshot.outboxState + ", history: "
                                    + snapshot.historyState
                                    + "). Delivery and edits remain fail-closed; data was not reset.";
                        } else if (snapshot.terminalNotice.length() > 0) {
                            state = snapshot.terminalNotice;
                        } else if (snapshot.nextAttemptAt > 0L) {
                            state = "Pending work has a scheduled foreground retry.";
                        } else {
                            state = "No report delivery is currently scheduled.";
                        }
                        reportState.setText(state);
                        reportState.setTextColor(snapshot.needsReview
                                || snapshot.terminalNotice.length() > 0
                                ? CloneBlockerUi.danger(CloneBlockerSettingsActivity.this)
                                : CloneBlockerUi.secondary(CloneBlockerSettingsActivity.this));
                    }
                });
    }
}
