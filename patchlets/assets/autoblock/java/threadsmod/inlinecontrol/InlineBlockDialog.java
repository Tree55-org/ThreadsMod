package threadsmod.inlinecontrol;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;

import java.util.concurrent.atomic.AtomicBoolean;

import threadsmod.reporting.ReportPayload;
import threadsmod.reporting.ReportRequest;

/** Compact native modal that explicitly queues one report and optionally one Block. */
final class InlineBlockDialog {
    private static final String[] REASON_LABELS = new String[] {
            "Red Bull / coordinated abuse",
            "Clone account",
            "Impersonation",
            "Scam",
            "Harassment",
            "Spam",
            "Other"
    };
    private static final String[] REASON_VALUES = new String[] {
            ReportPayload.REASON_REDBULL,
            ReportPayload.REASON_CLONE,
            ReportPayload.REASON_IMPERSONATION,
            ReportPayload.REASON_SCAM,
            ReportPayload.REASON_HARASSMENT,
            ReportPayload.REASON_SPAM,
            ReportPayload.REASON_OTHER
    };

    interface Listener {
        void onAlsoBlockChanged(boolean alsoBlock);

        void onSubmit(String reason, boolean alsoBlock);

        void onCancel();
    }

    private InlineBlockDialog() {}

    static void show(
            final Activity activity,
            final InlineBlockRequest request,
            final ReportRequest reportRequest,
            boolean alsoBlockEnabled,
            final Listener listener) {
        if (activity == null || request == null || reportRequest == null
                || !request.isValid() || !reportRequest.isValid()
                || !request.getMediaKey().equals(reportRequest.getItemKey())
                || !request.getAuthorId().equals(reportRequest.getProfileId())
                || listener == null) {
            throw new IllegalArgumentException("dialog arguments are required");
        }

        final InlineBlockStrings strings = InlineBlockStrings.forContext(activity);
        final CheckBox alsoBlock = checkBox(
                activity, strings.alsoBlockLabel, alsoBlockEnabled);

        ScrollView scroll = new ScrollView(activity);
        scroll.setFillViewport(true);
        LinearLayout content = column(activity);
        int outer = dp(activity, 20);
        content.setPadding(outer, dp(activity, 4), outer, dp(activity, 4));
        scroll.addView(content, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        LinearLayout identity = card(activity);
        String label = request.getLabel();
        identity.addView(heading(
                activity,
                label.length() == 0
                        ? "@" + reportRequest.getProfileUsername() : label,
                17));
        TextView metadata = secondary(activity, strings.accountMetadata(request.getAuthorId()));
        addTopMargin(activity, metadata, 4);
        identity.addView(metadata);
        content.addView(identity);

        LinearLayout post = card(activity);
        post.addView(heading(activity, strings.postExcerpt, 15));
        TextView excerpt = body(activity, reportRequest.getPostContent());
        addTopMargin(activity, excerpt, 7);
        excerpt.setTextIsSelectable(true);
        post.addView(excerpt);
        content.addView(post);

        LinearLayout options = card(activity);
        options.addView(heading(activity, strings.reportReason, 15));
        final Spinner reason = new Spinner(activity);
        ArrayAdapter<String> reasonAdapter = new ArrayAdapter<String>(
                activity, android.R.layout.simple_spinner_item, REASON_LABELS);
        reasonAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        reason.setAdapter(reasonAdapter);
        reason.setMinimumHeight(dp(activity, 48));
        options.addView(reason, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        options.addView(alsoBlock);
        TextView disclosure = secondary(activity, strings.disclosure);
        addTopMargin(activity, disclosure, 6);
        options.addView(disclosure);
        content.addView(options);

        final AtomicBoolean settled = new AtomicBoolean(false);
        final AlertDialog dialog = new AlertDialog.Builder(activity)
                .setTitle(strings.title)
                .setView(scroll)
                .setPositiveButton(alsoBlock.isChecked() ? strings.block : strings.report, null)
                .setNegativeButton(
                        strings.cancel,
                        new DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(DialogInterface ignored, int which) {
                                cancelOnce(settled, listener);
                            }
                        })
                .setOnCancelListener(new DialogInterface.OnCancelListener() {
                    @Override
                        public void onCancel(DialogInterface ignored) {
                            cancelOnce(settled, listener);
                        }
                })
                .create();

        dialog.setOnShowListener(new DialogInterface.OnShowListener() {
            @Override
            public void onShow(DialogInterface ignored) {
                final TextView positive = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
                if (positive != null) {
                    positive.setText(alsoBlock.isChecked() ? strings.block : strings.report);
                    alsoBlock.setOnCheckedChangeListener(
                            new CompoundButton.OnCheckedChangeListener() {
                                @Override
                                public void onCheckedChanged(
                                        CompoundButton button, boolean checked) {
                                    listener.onAlsoBlockChanged(checked);
                                    positive.setText(checked ? strings.block : strings.report);
                                }
                            });
                    positive.setOnClickListener(new View.OnClickListener() {
                        @Override
                        public void onClick(View view) {
                            if (!settled.compareAndSet(false, true)) {
                                return;
                            }
                            int position = Math.max(0, Math.min(
                                    REASON_VALUES.length - 1,
                                    reason.getSelectedItemPosition()));
                            listener.onAlsoBlockChanged(alsoBlock.isChecked());
                            listener.onSubmit(
                                    REASON_VALUES[position], alsoBlock.isChecked());
                            dialog.dismiss();
                        }
                    });
                }
            }
        });
        dialog.setOnDismissListener(new DialogInterface.OnDismissListener() {
            @Override
            public void onDismiss(DialogInterface ignored) {
                cancelOnce(settled, listener);
            }
        });
        dialog.show();
    }

    private static void cancelOnce(AtomicBoolean settled, Listener listener) {
        if (settled.compareAndSet(false, true)) {
            listener.onCancel();
        }
    }

    private static LinearLayout column(Activity activity) {
        LinearLayout view = new LinearLayout(activity);
        view.setOrientation(LinearLayout.VERTICAL);
        return view;
    }

    private static LinearLayout card(Activity activity) {
        LinearLayout view = column(activity);
        int padding = dp(activity, 14);
        view.setPadding(padding, padding, padding, padding);
        GradientDrawable background = new GradientDrawable();
        background.setColor(isDark(activity) ? Color.rgb(36, 36, 39) : Color.rgb(246, 246, 248));
        background.setCornerRadius(dp(activity, 12));
        background.setStroke(
                dp(activity, 1),
                isDark(activity) ? Color.rgb(65, 65, 70) : Color.rgb(224, 224, 229));
        view.setBackground(background);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(activity, 10);
        view.setLayoutParams(params);
        return view;
    }

    private static TextView heading(Activity activity, String text, int sizeSp) {
        TextView view = new TextView(activity);
        view.setText(text);
        view.setTextSize(sizeSp);
        view.setTextColor(foreground(activity));
        view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        view.setGravity(Gravity.START);
        view.setAccessibilityHeading(true);
        return view;
    }

    private static TextView secondary(Activity activity, String text) {
        TextView view = new TextView(activity);
        view.setText(text);
        view.setTextSize(12);
        view.setTextColor(isDark(activity) ? Color.rgb(188, 188, 194) : Color.rgb(86, 86, 94));
        view.setLineSpacing(0f, 1.12f);
        return view;
    }

    private static TextView body(Activity activity, String text) {
        TextView view = new TextView(activity);
        view.setText(text);
        view.setTextSize(14);
        view.setTextColor(foreground(activity));
        view.setLineSpacing(0f, 1.12f);
        return view;
    }

    private static CheckBox checkBox(Activity activity, String text, boolean checked) {
        CheckBox box = new CheckBox(activity);
        box.setText(text);
        box.setTextSize(14);
        box.setTextColor(foreground(activity));
        box.setChecked(checked);
        box.setMinHeight(dp(activity, 48));
        box.setGravity(Gravity.CENTER_VERTICAL);
        return box;
    }

    private static void addTopMargin(Activity activity, View view, int valueDp) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(activity, valueDp);
        view.setLayoutParams(params);
    }

    private static int foreground(Activity activity) {
        return isDark(activity) ? Color.rgb(245, 245, 247) : Color.rgb(25, 25, 28);
    }

    private static boolean isDark(Activity activity) {
        int mode = activity.getResources().getConfiguration().uiMode
                & Configuration.UI_MODE_NIGHT_MASK;
        return mode == Configuration.UI_MODE_NIGHT_YES;
    }

    private static int dp(Activity activity, int value) {
        return Math.round(value * activity.getResources().getDisplayMetrics().density);
    }

}
