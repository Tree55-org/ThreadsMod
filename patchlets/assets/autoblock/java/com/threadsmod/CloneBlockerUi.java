package com.threadsmod;

import android.content.Context;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Small resource-free styling helpers shared by the two mod activities. */
final class CloneBlockerUi {
    private CloneBlockerUi() {}

    static boolean isDark(Context context) {
        int mode = context.getResources().getConfiguration().uiMode
                & Configuration.UI_MODE_NIGHT_MASK;
        return mode == Configuration.UI_MODE_NIGHT_YES;
    }

    static int background(Context context) {
        return isDark(context) ? Color.rgb(16, 16, 18) : Color.rgb(248, 248, 250);
    }

    static int cardColor(Context context) {
        return isDark(context) ? Color.rgb(31, 31, 34) : Color.WHITE;
    }

    static int foreground(Context context) {
        return isDark(context) ? Color.rgb(245, 245, 247) : Color.rgb(24, 24, 27);
    }

    static int secondary(Context context) {
        return isDark(context) ? Color.rgb(178, 178, 184) : Color.rgb(92, 92, 100);
    }

    static int border(Context context) {
        return isDark(context) ? Color.rgb(58, 58, 63) : Color.rgb(226, 226, 231);
    }

    static int accent(Context context) {
        return isDark(context) ? Color.rgb(246, 246, 248) : Color.rgb(24, 24, 27);
    }

    static int success() {
        return Color.rgb(46, 158, 91);
    }

    static int danger(Context context) {
        return isDark(context) ? Color.rgb(255, 123, 123) : Color.rgb(177, 42, 42);
    }

    static int dp(Context context, int value) {
        return Math.round(value * context.getResources().getDisplayMetrics().density);
    }

    static LinearLayout column(Context context) {
        LinearLayout layout = new LinearLayout(context);
        layout.setOrientation(LinearLayout.VERTICAL);
        return layout;
    }

    static LinearLayout card(Context context) {
        LinearLayout layout = column(context);
        int padding = dp(context, 16);
        layout.setPadding(padding, padding, padding, padding);
        GradientDrawable background = new GradientDrawable();
        background.setColor(cardColor(context));
        background.setCornerRadius(dp(context, 16));
        background.setStroke(dp(context, 1), border(context));
        layout.setBackground(background);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(context, 12);
        layout.setLayoutParams(params);
        return layout;
    }

    static TextView title(Context context, String text) {
        TextView view = text(context, text, 28, foreground(context));
        view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        return view;
    }

    static TextView sectionTitle(Context context, String text) {
        TextView view = text(context, text, 17, foreground(context));
        view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        return view;
    }

    static TextView body(Context context, String text) {
        TextView view = text(context, text, 15, foreground(context));
        view.setLineSpacing(0f, 1.12f);
        return view;
    }

    static TextView secondary(Context context, String text) {
        TextView view = text(context, text, 13, secondary(context));
        view.setLineSpacing(0f, 1.1f);
        return view;
    }

    static TextView text(Context context, String text, int sizeSp, int color) {
        TextView view = new TextView(context);
        view.setText(text);
        view.setTextSize(sizeSp);
        view.setTextColor(color);
        return view;
    }

    static Button button(Context context, String text) {
        Button button = new Button(context);
        button.setText(text);
        button.setTextSize(14);
        button.setAllCaps(false);
        button.setMinHeight(dp(context, 48));
        return button;
    }

    static void addTopSpace(Context context, View view, int dp) {
        ViewGroup.LayoutParams raw = view.getLayoutParams();
        LinearLayout.LayoutParams params;
        if (raw instanceof LinearLayout.LayoutParams) {
            params = (LinearLayout.LayoutParams) raw;
        } else {
            params = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT);
        }
        params.topMargin = CloneBlockerUi.dp(context, dp);
        view.setLayoutParams(params);
    }
}
