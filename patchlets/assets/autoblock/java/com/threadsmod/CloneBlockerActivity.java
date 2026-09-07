package com.threadsmod;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.DialogInterface;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;

import threadsmod.autoblock.AutoBlockSync;
import threadsmod.autoblock.ModStateStore;
import threadsmod.reporting.ReportClient;
import threadsmod.reporting.ReportStore;

/** Threads-only activity, queue, retry, and bounded history dashboard. */
public final class CloneBlockerActivity extends Activity {
    private static final int MAX_VISIBLE_QUEUE = 30;
    private static final int MAX_VISIBLE_HISTORY = 40;
    private static final int MAX_VISIBLE_REPORTS = 20;
    private static final long STATUS_POLL_INTERVAL_MS = 1000L;
    private static final String STATUS_POLL_UNAVAILABLE =
            "Unavailable: live block-list status refresh stopped. Reopen this page.";
    private static final String[] FILTERS = {
            "All", "Blocked", "Failed", "Abandoned", "Queued"
    };

    private int selectedFilter;
    private ScrollView scroll;
    private TextView currentStatusValue;
    private TextView listStatusValue;
    private Button syncButton;
    private boolean statusContentReady;
    private boolean statusPolling;
    private boolean statusPollingUnavailable;
    private final Handler statusHandler = new Handler(Looper.getMainLooper());
    private final Runnable statusPoll = new Runnable() {
        @Override
        public void run() {
            if (!statusPolling || !statusContentReady) {
                return;
            }
            refreshPolledStatus();
            if (statusPolling && !statusHandler.postDelayed(this, STATUS_POLL_INTERVAL_MS)) {
                showStatusPollingUnavailable();
            }
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        setTheme(android.R.style.Theme_DeviceDefault_NoActionBar);
        super.onCreate(savedInstanceState);
        setTitle("Clone Blocker activity");
        rebuild();
    }

    @Override
    protected void onResume() {
        super.onResume();
        rebuild();
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

    private void rebuild() {
        statusContentReady = false;
        currentStatusValue = null;
        listStatusValue = null;
        syncButton = null;
        int oldY = scroll == null ? 0 : scroll.getScrollY();

        scroll = new ScrollView(this);
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
        // Corrupt legacy preferences must fail closed into an on-screen review state, not leave
        // an empty Activity window or terminate before setContentView().
        setContentView(scroll);
        try {
            final ModStateStore.Snapshot snapshot = ModStateStore.snapshot(this);
            addHeader(root);
            addStatusFirst(root, snapshot);
            addStats(root, snapshot);
            addSync(root);
            addReports(root, snapshot.viewerId);
            addQueue(root, snapshot);
            addHistory(root, snapshot);
            statusContentReady = true;
        } catch (RuntimeException invalidLocalState) {
            root.removeAllViews();
            addHeader(root);
            LinearLayout failure = CloneBlockerUi.card(this);
            TextView heading = CloneBlockerUi.sectionTitle(
                    this, "Activity data needs review");
            heading.setTextColor(CloneBlockerUi.danger(this));
            failure.addView(heading);
            TextView detail = CloneBlockerUi.body(
                    this,
                    "Local activity state could not be rendered. Blocking remains fail-closed; "
                            + "return to a signed-in Threads feed, then refresh this page. "
                            + "Stored data was not reset.");
            detail.setTextColor(CloneBlockerUi.danger(this));
            CloneBlockerUi.addTopSpace(this, detail, 8);
            failure.addView(detail);
            root.addView(failure);
        }
        final int restoreY = oldY;
        if (restoreY > 0) {
            scroll.post(new Runnable() {
                @Override
                public void run() {
                    scroll.scrollTo(0, restoreY);
                }
            });
        }
    }

    private void addHeader(LinearLayout root) {
        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = CloneBlockerUi.title(this, "Activity");
        header.addView(title, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button refresh = CloneBlockerUi.button(this, "Refresh");
        refresh.setContentDescription("Refresh Clone Blocker activity");
        refresh.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                rebuild();
            }
        });
        header.addView(refresh);
        Button settings = CloneBlockerUi.button(this, "Settings");
        settings.setContentDescription("Open Clone Blocker settings");
        settings.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                startActivity(new Intent(
                        CloneBlockerActivity.this,
                        CloneBlockerSettingsActivity.class));
            }
        });
        header.addView(settings);
        root.addView(header);

        TextView account = CloneBlockerUi.secondary(
                this,
                ModStateStore.getActiveViewer(this).length() == 0
                        ? "Open a signed-in Threads feed to select its local activity scope."
                        : "Viewer scope: Threads account " + ModStateStore.getActiveViewer(this));
        CloneBlockerUi.addTopSpace(this, account, 6);
        root.addView(account);
    }

    /** Failure and runtime status intentionally precede metrics and history. */
    private void addStatusFirst(LinearLayout root, ModStateStore.Snapshot snapshot) {
        ModStateStore.AlertItem alert = snapshot.latestAlert();
        String inferred = failureLike(snapshot.status) ? snapshot.status : "";
        if (alert != null || inferred.length() > 0) {
            LinearLayout failure = CloneBlockerUi.card(this);
            TextView heading = CloneBlockerUi.sectionTitle(this, "Needs attention");
            heading.setTextColor(CloneBlockerUi.danger(this));
            failure.addView(heading);
            String message = alert != null ? alert.message : inferred;
            TextView detail = CloneBlockerUi.body(this, message);
            detail.setTextColor(CloneBlockerUi.danger(this));
            CloneBlockerUi.addTopSpace(this, detail, 8);
            failure.addView(detail);
            if (alert != null) {
                TextView when = CloneBlockerUi.secondary(
                        this, alert.code + " · " + formatTime(alert.timestamp));
                CloneBlockerUi.addTopSpace(this, when, 6);
                failure.addView(when);
            }
            if (snapshot.viewerId.length() > 0 && alert != null) {
                Button dismiss = CloneBlockerUi.button(this, "Clear notices");
                CloneBlockerUi.addTopSpace(this, dismiss, 8);
                dismiss.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View view) {
                        String viewer = ModStateStore.getActiveViewer(CloneBlockerActivity.this);
                        ModStateStore.clearAlerts(CloneBlockerActivity.this, viewer);
                        rebuild();
                    }
                });
                failure.addView(dismiss);
            }
            root.addView(failure);
        }

        LinearLayout status = CloneBlockerUi.card(this);
        status.addView(CloneBlockerUi.sectionTitle(this, "Current status"));
        currentStatusValue = CloneBlockerUi.body(this, snapshot.status);
        CloneBlockerUi.addTopSpace(this, currentStatusValue, 8);
        status.addView(currentStatusValue);
        listStatusValue = CloneBlockerUi.body(this, AutoBlockSync.getListStatus(this));
        CloneBlockerUi.addTopSpace(this, listStatusValue, 8);
        status.addView(listStatusValue);
        TextView state = CloneBlockerUi.secondary(
                this,
                "State: " + (snapshot.runtimeCode.length() == 0
                        ? "idle" : snapshot.runtimeCode)
                        + (snapshot.runtimeAt > 0L
                        ? " · " + formatTime(snapshot.runtimeAt) : "")
                        + (AutoBlockSync.isRunning() ? " · running" : ""));
        CloneBlockerUi.addTopSpace(this, state, 6);
        status.addView(state);
        root.addView(status);
    }

    private void addStats(LinearLayout root, ModStateStore.Snapshot snapshot) {
        TextView heading = CloneBlockerUi.sectionTitle(this, "Overview");
        CloneBlockerUi.addTopSpace(this, heading, 18);
        root.addView(heading);
        addStatRow(root,
                "Blocked", snapshot.blocked,
                "Queued", snapshot.queued);
        addStatRow(root,
                "Last hour", snapshot.lastHour,
                "Today", snapshot.today);
        addStatRow(root,
                "Failed / abandoned", snapshot.failedOrAbandoned,
                "Indexed profiles", snapshot.blocklistSize);
    }

    private void addStatRow(
            LinearLayout root,
            String leftLabel,
            int leftValue,
            String rightLabel,
            int rightValue) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        CloneBlockerUi.addTopSpace(this, row, 10);
        LinearLayout left = statCard(leftLabel, leftValue);
        LinearLayout right = statCard(rightLabel, rightValue);
        LinearLayout.LayoutParams leftParams = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        leftParams.rightMargin = CloneBlockerUi.dp(this, 5);
        LinearLayout.LayoutParams rightParams = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        rightParams.leftMargin = CloneBlockerUi.dp(this, 5);
        row.addView(left, leftParams);
        row.addView(right, rightParams);
        root.addView(row);
    }

    private LinearLayout statCard(String label, int value) {
        LinearLayout card = CloneBlockerUi.card(this);
        TextView number = CloneBlockerUi.text(
                this, String.valueOf(value), 24, CloneBlockerUi.foreground(this));
        number.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        card.addView(number);
        TextView caption = CloneBlockerUi.secondary(this, label);
        CloneBlockerUi.addTopSpace(this, caption, 2);
        card.addView(caption);
        return card;
    }

    private void addSync(LinearLayout root) {
        LinearLayout card = CloneBlockerUi.card(this);
        card.addView(CloneBlockerUi.sectionTitle(this, "Passive block list"));
        TextView mirrors = CloneBlockerUi.secondary(
                this,
                "Refreshes every 10 minutes while Threads is foreground. Only listed profiles whose post or reply action row is actually visible are admitted to blocking.");
        CloneBlockerUi.addTopSpace(this, mirrors, 8);
        card.addView(mirrors);
        syncButton = CloneBlockerUi.button(this, "Sync now");
        syncButton.setEnabled(!AutoBlockSync.isRunning() && !AutoBlockSync.isRefreshingList());
        CloneBlockerUi.addTopSpace(this, syncButton, 10);
        syncButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                AutoBlockSync.enableAndSync(CloneBlockerActivity.this);
                Toast.makeText(CloneBlockerActivity.this,
                        "Sync requested. Return to the Threads feed to continue.",
                        Toast.LENGTH_SHORT).show();
                rebuild();
            }
        });
        card.addView(syncButton);
        root.addView(card);
    }

    private void startStatusPolling() {
        statusHandler.removeCallbacks(statusPoll);
        statusPolling = statusContentReady;
        statusPollingUnavailable = false;
        if (!statusPolling) {
            return;
        }
        refreshPolledStatus();
        if (statusPolling
                && !statusHandler.postDelayed(statusPoll, STATUS_POLL_INTERVAL_MS)) {
            showStatusPollingUnavailable();
        }
    }

    private void stopStatusPolling() {
        statusPolling = false;
        statusHandler.removeCallbacks(statusPoll);
    }

    private void refreshPolledStatus() {
        if (!statusContentReady) {
            return;
        }
        try {
            if (currentStatusValue != null) {
                currentStatusValue.setText(AutoBlockSync.getStatus(this));
            }
            if (listStatusValue != null) {
                String listStatus = AutoBlockSync.getListStatus(this);
                listStatusValue.setText(statusPollingUnavailable
                        ? listStatus + "\n" + STATUS_POLL_UNAVAILABLE : listStatus);
            }
            if (syncButton != null) {
                syncButton.setText("Sync now");
                syncButton.setEnabled(
                        !AutoBlockSync.isRunning() && !AutoBlockSync.isRefreshingList());
            }
        } catch (RuntimeException unavailable) {
            showStatusPollingUnavailable();
        }
    }

    private void showStatusPollingUnavailable() {
        statusPolling = false;
        statusPollingUnavailable = true;
        statusHandler.removeCallbacks(statusPoll);
        if (listStatusValue != null) {
            CharSequence current = listStatusValue.getText();
            String prefix = current == null ? "" : current.toString();
            if (!prefix.contains(STATUS_POLL_UNAVAILABLE)) {
                listStatusValue.setText(prefix.length() == 0
                        ? STATUS_POLL_UNAVAILABLE
                        : prefix + "\n" + STATUS_POLL_UNAVAILABLE);
            }
            listStatusValue.setTextColor(CloneBlockerUi.danger(this));
        }
    }

    private void addReports(LinearLayout root, final String viewerId) {
        final LinearLayout card = CloneBlockerUi.card(this);
        card.addView(CloneBlockerUi.sectionTitle(this, "Report outbox"));
        TextView loading = CloneBlockerUi.secondary(
                this,
                viewerId.length() == 0
                        ? "Open a signed-in Threads feed to select a report scope."
                        : "Loading viewer-scoped report state…");
        CloneBlockerUi.addTopSpace(this, loading, 8);
        card.addView(loading);
        root.addView(card);
        ReportClient.getLocalStatusAsync(
                this,
                viewerId,
                new ReportClient.LocalStatusCallback() {
                    @Override
                    public void onStatus(ReportStore.Snapshot snapshot) {
                        if (isFinishing() || isDestroyed() || card.getParent() == null
                                || !viewerId.equals(ModStateStore.getActiveViewer(
                                CloneBlockerActivity.this))) {
                            return;
                        }
                        populateReports(card, viewerId, snapshot);
                    }
                });
    }

    private void populateReports(
            final LinearLayout card,
            final String viewerId,
            final ReportStore.Snapshot reports) {
        card.removeAllViews();
        LinearLayout headingRow = new LinearLayout(this);
        headingRow.setOrientation(LinearLayout.HORIZONTAL);
        headingRow.setGravity(Gravity.CENTER_VERTICAL);
        headingRow.addView(
                CloneBlockerUi.sectionTitle(this, "Report outbox"),
                new LinearLayout.LayoutParams(
                        0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button retry = CloneBlockerUi.button(this, "Retry all");
        retry.setEnabled(reports.pendingCount > 0 && viewerId.length() > 0
                && !reports.needsReview);
        retry.setContentDescription("Make pending reports eligible on the next foreground return");
        retry.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                view.setEnabled(false);
                ReportClient.retryPendingNowAsync(
                        CloneBlockerActivity.this,
                        viewerId,
                        new ReportClient.RetryCallback() {
                            @Override
                            public void onRetryRequested(
                                    boolean changed, ReportStore.Snapshot snapshot) {
                                Toast.makeText(
                                        CloneBlockerActivity.this,
                                        changed
                                                ? "Reports are ready; return to the Threads feed to deliver them."
                                                : "No eligible pending report changed.",
                                        Toast.LENGTH_LONG).show();
                                if (!isFinishing() && !isDestroyed()
                                        && card.getParent() != null
                                        && viewerId.equals(ModStateStore.getActiveViewer(
                                        CloneBlockerActivity.this))) {
                                    populateReports(card, viewerId, snapshot);
                                }
                            }
                        });
            }
        });
        headingRow.addView(retry);
        card.addView(headingRow);

        TextView counts = CloneBlockerUi.body(
                this,
                "Pending " + reports.pendingCount
                        + "  ·  Sent " + reports.sentCount
                        + "  ·  Rejected " + reports.rejectedCount
                        + "  ·  Unconfirmed " + reports.gaveUpCount);
        CloneBlockerUi.addTopSpace(this, counts, 8);
        card.addView(counts);
        if (reports.needsReview) {
            TextView review = CloneBlockerUi.body(
                    this,
                    "Local report storage needs review (outbox: "
                            + reports.outboxState + ", history: " + reports.historyState
                            + "). Delivery, retry, and deletion remain fail-closed; stored data was not reset.");
            review.setTextColor(CloneBlockerUi.danger(this));
            CloneBlockerUi.addTopSpace(this, review, 8);
            card.addView(review);
        }
        if (reports.terminalNotice.length() > 0) {
            TextView terminal = CloneBlockerUi.body(
                    this,
                    reports.terminalNotice
                            + (reports.terminalNoticeAt > 0L
                            ? "\n" + formatTime(reports.terminalNoticeAt) : ""));
            terminal.setTextColor(CloneBlockerUi.danger(this));
            CloneBlockerUi.addTopSpace(this, terminal, 8);
            card.addView(terminal);
        }
        TextView boundary = CloneBlockerUi.secondary(
                this,
                reports.needsReview
                        ? "No report delivery is attempted until the local database state can be reviewed."
                        : reports.nextAttemptAt > 0L
                        ? "Next eligible foreground attempt: "
                                + formatTime(reports.nextAttemptAt)
                        : "No report delivery is scheduled. Reports are queued only after an explicit Block or Report tap in the combined modal and are delivered only while the main Threads UI is foregrounded.");
        CloneBlockerUi.addTopSpace(this, boundary, 6);
        card.addView(boundary);

        int shown = 0;
        for (final ReportStore.PendingEntry pending : reports.pending) {
            if (shown++ >= MAX_VISIBLE_REPORTS) {
                break;
            }
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            CloneBlockerUi.addTopSpace(this, row, 10);
            LinearLayout copy = CloneBlockerUi.column(this);
            copy.addView(CloneBlockerUi.body(
                    this,
                    "@" + pending.profileUsername + " · " + pending.profileId));
            String metadata = pending.reason + " · attempts " + pending.attempts
                    + " · next " + formatTime(pending.nextAttemptAt);
            if (pending.lastError.length() > 0) {
                metadata += "\n" + pending.lastError
                        + (pending.lastHttpStatus > 0
                        ? " (HTTP " + pending.lastHttpStatus + ")" : "");
            }
            if (pending.postContent.length() > 0) {
                metadata += "\n“" + pending.postContent + "”";
            }
            copy.addView(CloneBlockerUi.secondary(this, metadata));
            row.addView(copy, new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            Button cancel = CloneBlockerUi.button(this, "Cancel");
            cancel.setText(pending.inFlight ? "Sending" : "Delete");
            cancel.setEnabled(!pending.inFlight && !reports.needsReview);
            cancel.setContentDescription(
                    pending.inFlight
                            ? "Report delivery is active for " + pending.profileUsername
                            : "Delete pending report for " + pending.profileUsername);
            cancel.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View view) {
                    confirmCancelReport(viewerId, pending);
                }
            });
            row.addView(cancel);
            card.addView(row);
        }
        if (reports.pendingCount > MAX_VISIBLE_REPORTS) {
            TextView more = CloneBlockerUi.secondary(
                    this,
                    "+ " + (reports.pendingCount - MAX_VISIBLE_REPORTS)
                            + " more pending reports");
            CloneBlockerUi.addTopSpace(this, more, 8);
            card.addView(more);
        }
        TextView retention = CloneBlockerUi.secondary(
                this,
                "Every accepted action is stored before network delivery. Pending payloads can remain indefinitely until sent, terminally rejected/given up, or explicitly deleted. Local terminal history retains at most 500 records with no time-based expiry. Cancellation can race an active POST and cannot retract a server-accepted copy.");
        CloneBlockerUi.addTopSpace(this, retention, 10);
        card.addView(retention);
    }

    private void confirmCancelReport(
            final String viewerId,
            final ReportStore.PendingEntry pending) {
        new AlertDialog.Builder(this)
                .setTitle("Cancel pending report?")
                .setMessage("This requests permanent deletion of the local pending payload for @"
                        + pending.profileUsername + ". If delivery becomes active first, deletion fails and the POST may still complete. Deleting locally cannot retract a server-accepted copy.")
                .setNegativeButton("Keep", null)
                .setPositiveButton("Delete", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        ReportClient.cancelPendingAsync(
                                CloneBlockerActivity.this,
                                viewerId,
                                pending.reportId,
                                new ReportClient.CancelCallback() {
                                    @Override
                                    public void onCancelled(
                                            ReportStore.CancelResult result,
                                            ReportStore.Snapshot snapshot) {
                                        String message;
                                        if (ReportStore.CancelResult.DELETED.equals(result.status)) {
                                            message = "Pending report deleted locally.";
                                        } else if (ReportStore.CancelResult.IN_FLIGHT.equals(result.status)) {
                                            message = "Delivery already started; the report was not deleted and may still be accepted.";
                                        } else if (ReportStore.CancelResult.NEEDS_REVIEW.equals(result.status)) {
                                            message = "Local report storage needs review; no data was changed.";
                                        } else if (ReportStore.CancelResult.NOT_FOUND.equals(result.status)) {
                                            message = "The report is no longer pending; it may already have completed.";
                                        } else {
                                            message = "The pending report could not be deleted; no success is being claimed.";
                                        }
                                        Toast.makeText(
                                                CloneBlockerActivity.this,
                                                message,
                                                Toast.LENGTH_LONG).show();
                                        if (!isFinishing() && !isDestroyed()) {
                                            rebuild();
                                        }
                                    }
                                });
                    }
                })
                .show();
    }

    private void addQueue(LinearLayout root, final ModStateStore.Snapshot snapshot) {
        LinearLayout card = CloneBlockerUi.card(this);
        LinearLayout headingRow = new LinearLayout(this);
        headingRow.setOrientation(LinearLayout.HORIZONTAL);
        headingRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView heading = CloneBlockerUi.sectionTitle(this, "Manual queue");
        headingRow.addView(heading, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button retryAll = CloneBlockerUi.button(this, "Retry all");
        retryAll.setEnabled(hasRetryable(snapshot.queue));
        retryAll.setContentDescription("Retry all failed or abandoned manual blocks");
        retryAll.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                int changed = ModStateStore.retryAllManual(
                        CloneBlockerActivity.this, snapshot.viewerId);
                if (changed > 0) {
                    ModStateStore.notifyManualQueueChanged(CloneBlockerActivity.this);
                }
                Toast.makeText(CloneBlockerActivity.this,
                        changed == 0 ? "Nothing needs retry." : changed + " target(s) queued.",
                        Toast.LENGTH_SHORT).show();
                rebuild();
            }
        });
        headingRow.addView(retryAll);
        card.addView(headingRow);

        if (snapshot.queue.isEmpty()) {
            TextView empty = CloneBlockerUi.secondary(
                    this, "No manual targets are waiting. Inline Block actions appear here while queued or after a failure.");
            CloneBlockerUi.addTopSpace(this, empty, 8);
            card.addView(empty);
        } else {
            int shown = 0;
            for (final ModStateStore.QueueItem item : snapshot.queue) {
                if (shown++ >= MAX_VISIBLE_QUEUE) {
                    break;
                }
                addQueueItem(card, snapshot.viewerId, item);
            }
            if (snapshot.queue.size() > MAX_VISIBLE_QUEUE) {
                TextView more = CloneBlockerUi.secondary(
                        this,
                        "+ " + (snapshot.queue.size() - MAX_VISIBLE_QUEUE)
                                + " more local queue entries");
                CloneBlockerUi.addTopSpace(this, more, 8);
                card.addView(more);
            }
        }
        root.addView(card);
    }

    private void addQueueItem(
            LinearLayout parent,
            final String viewerId,
            final ModStateStore.QueueItem item) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, CloneBlockerUi.dp(this, 10), 0, 0);
        LinearLayout copy = CloneBlockerUi.column(this);
        String primary = item.label.length() > 0 ? item.label : "Threads user";
        copy.addView(CloneBlockerUi.body(this, primary));
        String metadata = item.targetId + " · " + item.state
                + " · attempts " + item.attempts;
        if (item.error.length() > 0) {
            metadata += "\n" + item.error;
        }
        copy.addView(CloneBlockerUi.secondary(this, metadata));
        row.addView(copy, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        boolean retryable = ModStateStore.STATE_FAILED.equals(item.state)
                || ModStateStore.STATE_ABANDONED.equals(item.state);
        Button retry = CloneBlockerUi.button(this, retryable ? "Retry" : item.state);
        retry.setEnabled(retryable);
        retry.setContentDescription("Retry blocking Threads user " + item.targetId);
        retry.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                boolean changed = ModStateStore.retryManual(
                        CloneBlockerActivity.this, viewerId, item.targetId);
                if (changed) {
                    ModStateStore.notifyManualQueueChanged(CloneBlockerActivity.this);
                }
                Toast.makeText(CloneBlockerActivity.this,
                        changed ? "Target queued for retry." : "Target was not retryable.",
                        Toast.LENGTH_SHORT).show();
                rebuild();
            }
        });
        row.addView(retry);
        parent.addView(row);
    }

    private void addHistory(LinearLayout root, final ModStateStore.Snapshot snapshot) {
        LinearLayout card = CloneBlockerUi.card(this);
        card.addView(CloneBlockerUi.sectionTitle(this, "History"));

        Spinner filter = new Spinner(this);
        ArrayAdapter<String> adapter = new ArrayAdapter<String>(
                this, android.R.layout.simple_spinner_item, FILTERS);
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        filter.setAdapter(adapter);
        filter.setSelection(Math.max(0, Math.min(FILTERS.length - 1, selectedFilter)));
        CloneBlockerUi.addTopSpace(this, filter, 8);
        card.addView(filter, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                CloneBlockerUi.dp(this, 48)));

        final LinearLayout entries = CloneBlockerUi.column(this);
        card.addView(entries, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        renderHistory(entries, snapshot, selectedFilter);
        filter.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override
            public void onItemSelected(
                    AdapterView<?> parent, View view, int position, long id) {
                selectedFilter = position;
                renderHistory(entries, snapshot, position);
            }

            @Override
            public void onNothingSelected(AdapterView<?> parent) {
                // Preserve the last explicit filter.
            }
        });
        root.addView(card);
    }

    private void renderHistory(
            LinearLayout parent,
            ModStateStore.Snapshot snapshot,
            int filter) {
        parent.removeAllViews();
        int shown = 0;
        if (filter == 4) {
            for (ModStateStore.QueueItem item : snapshot.queue) {
                if (shown++ >= MAX_VISIBLE_HISTORY) {
                    break;
                }
                TextView entry = CloneBlockerUi.body(
                        this,
                        displayTarget(item.label, item.targetId) + "\n"
                                + item.state + " · " + formatTime(item.updatedAt));
                CloneBlockerUi.addTopSpace(this, entry, 10);
                parent.addView(entry);
            }
        } else {
            for (ModStateStore.HistoryItem item : snapshot.history) {
                if (!matchesFilter(item, filter)) {
                    continue;
                }
                if (shown++ >= MAX_VISIBLE_HISTORY) {
                    break;
                }
                String detail = displayTarget(item.label, item.targetId) + "\n"
                        + item.outcome + " · " + friendlySource(item.source)
                        + " · " + formatTime(item.timestamp);
                if (item.detail.length() > 0) {
                    detail += "\n" + item.detail;
                }
                TextView entry = CloneBlockerUi.body(this, detail);
                if (ModStateStore.OUTCOME_BLOCKED.equals(item.outcome)) {
                    entry.setTextColor(CloneBlockerUi.success());
                } else {
                    entry.setTextColor(CloneBlockerUi.danger(this));
                }
                CloneBlockerUi.addTopSpace(this, entry, 10);
                parent.addView(entry);
            }
        }
        if (shown == 0) {
            TextView empty = CloneBlockerUi.secondary(this, "No matching local activity yet.");
            CloneBlockerUi.addTopSpace(this, empty, 10);
            parent.addView(empty);
        } else if (shown >= MAX_VISIBLE_HISTORY) {
            TextView bounded = CloneBlockerUi.secondary(
                    this, "Showing the newest " + MAX_VISIBLE_HISTORY + " matching entries.");
            CloneBlockerUi.addTopSpace(this, bounded, 10);
            parent.addView(bounded);
        }
    }

    private static boolean matchesFilter(ModStateStore.HistoryItem item, int filter) {
        if (filter == 0) {
            return true;
        }
        if (filter == 1) {
            return ModStateStore.OUTCOME_BLOCKED.equals(item.outcome);
        }
        if (filter == 2) {
            return ModStateStore.OUTCOME_FAILED.equals(item.outcome);
        }
        if (filter == 3) {
            return ModStateStore.OUTCOME_ABANDONED.equals(item.outcome);
        }
        return false;
    }

    private static boolean hasRetryable(List<ModStateStore.QueueItem> queue) {
        for (ModStateStore.QueueItem item : queue) {
            if (ModStateStore.STATE_FAILED.equals(item.state)
                    || ModStateStore.STATE_ABANDONED.equals(item.state)) {
                return true;
            }
        }
        return false;
    }

    private static String friendlySource(String source) {
        return ModStateStore.SOURCE_SIGNED_LIST.equals(source)
                ? "passive list" : "inline";
    }

    private static String displayTarget(String label, String targetId) {
        return label == null || label.length() == 0
                ? "Threads user " + targetId : label + " · " + targetId;
    }

    private static boolean failureLike(String status) {
        if (status == null) {
            return false;
        }
        String value = status.toLowerCase(Locale.US);
        return value.contains("fail") || value.contains("stopped")
                || value.contains("error") || value.contains("paused after");
    }

    private static String formatTime(long value) {
        if (value <= 0L) {
            return "unknown time";
        }
        return new SimpleDateFormat("MMM d, HH:mm", Locale.getDefault())
                .format(new Date(value));
    }
}
