package com.threadsmod;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
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

import java.util.Arrays;

import threadsmod.proxy.ProxyConfig;
import threadsmod.proxy.ProxyConfigStore;
import threadsmod.proxy.ProxyController;
import threadsmod.proxy.Socks5VpnService;

/** Private, resource-free SOCKS5 configuration surface for the cloned app. */
public final class ProxySettingsActivity extends Activity {
    private static final int VPN_PERMISSION_REQUEST = 0x5355;
    private static final long STATUS_REFRESH_MILLIS = 500L;

    private final Handler statusHandler = new Handler(Looper.getMainLooper());
    private final Runnable statusRefreshTask = new Runnable() {
        @Override
        public void run() {
            if (!statusPolling || !contentReady) {
                return;
            }
            String runtimeState = Socks5VpnService.runtimeState();
            if (!runtimeState.equals(observedRuntimeState)) {
                observedRuntimeState = runtimeState;
                refreshStatus();
            }
            if (!statusHandler.postDelayed(this, STATUS_REFRESH_MILLIS)) {
                statusPolling = false;
                showStatusRefreshUnavailable();
            }
        }
    };

    private TextView statusValue;
    private Switch enabledSwitch;
    private EditText hostInput;
    private EditText portInput;
    private Switch authSwitch;
    private EditText usernameInput;
    private EditText passwordInput;
    private EditText bypassInput;
    private Button saveButton;
    private boolean contentReady;
    private boolean savedPasswordAvailable;
    private boolean sensitiveFieldsCleared;
    private boolean statusPolling;
    private String observedRuntimeState = "";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        setTheme(android.R.style.Theme_DeviceDefault_NoActionBar);
        super.onCreate(savedInstanceState);
        setTitle("SOCKS5 proxy settings");
        buildContent();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (contentReady) {
            restoreSensitiveFieldsIfNeeded();
            refreshStatus();
            startStatusPolling();
        }
    }

    @Override
    protected void onPause() {
        stopStatusPolling();
        if (usernameInput != null) {
            usernameInput.setText("");
        }
        if (passwordInput != null) {
            passwordInput.setText("");
        }
        sensitiveFieldsCleared = true;
        super.onPause();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, android.content.Intent data) {
        if (requestCode == VPN_PERMISSION_REQUEST) {
            boolean accepted = ProxyController.handleActivityResult(
                    this, requestCode, resultCode);
            Toast.makeText(
                    this,
                    accepted
                            ? "VPN approval received; connecting in the background."
                            : "VPN approval was not granted. The proxy is inactive and direct traffic may continue.",
                    Toast.LENGTH_LONG).show();
            refreshStatus();
            return;
        }
        super.onActivityResult(requestCode, resultCode, data);
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

        // Attach a visible shell before reading encrypted preferences or building dynamic cards.
        setContentView(scroll);
        try {
            TextView title = CloneBlockerUi.title(this, "SOCKS5 proxy");
            root.addView(title);
            TextView intro = CloneBlockerUi.secondary(
                    this,
                    "Route this cloned Threads app through one SOCKS5 server. The official Threads app is not selected.");
            CloneBlockerUi.addTopSpace(this, intro, 6);
            root.addView(intro);

            LinearLayout statusCard = CloneBlockerUi.card(this);
            statusCard.addView(CloneBlockerUi.sectionTitle(this, "Proxy status"));
            statusValue = CloneBlockerUi.body(this, "Loading…");
            CloneBlockerUi.addTopSpace(this, statusValue, 8);
            statusCard.addView(statusValue);
            root.addView(statusCard);

            LinearLayout connectionCard = CloneBlockerUi.card(this);
            connectionCard.addView(CloneBlockerUi.sectionTitle(this, "Connection"));
            enabledSwitch = settingSwitch(
                    "Route this app through SOCKS5",
                    "After Android establishes the VPN, tunnel failures stay fail-closed. Before approval, direct traffic may continue.",
                    connectionCard);
            hostInput = textSetting(
                    "Server",
                    "Hostname, IPv4, or IPv6 address",
                    InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI,
                    true,
                    connectionCard);
            portInput = textSetting(
                    "Port",
                    "1–65535",
                    InputType.TYPE_CLASS_NUMBER,
                    true,
                    connectionCard);
            root.addView(connectionCard);

            LinearLayout authCard = CloneBlockerUi.card(this);
            authCard.addView(CloneBlockerUi.sectionTitle(this, "Authentication"));
            authSwitch = settingSwitch(
                    "Use username and password",
                    "Credentials use printable ASCII and are encrypted with Android Keystore before persistence.",
                    authCard);
            usernameInput = textSetting(
                    "Username",
                    "1–255 printable ASCII bytes",
                    InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
                    true,
                    authCard);
            usernameInput.setSaveEnabled(false);
            usernameInput.setImportantForAutofill(
                    View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
            passwordInput = textSetting(
                    "Password",
                    "Leave blank to keep a valid saved password",
                    InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD,
                    false,
                    authCard);
            passwordInput.setSaveEnabled(false);
            passwordInput.setImportantForAutofill(
                    View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
            root.addView(authCard);

            LinearLayout bypassCard = CloneBlockerUi.card(this);
            bypassCard.addView(CloneBlockerUi.sectionTitle(this, "Bypass proxy"));
            TextView bypassHelp = CloneBlockerUi.secondary(
                    this,
                    "Optional DIRECT exceptions. Enter one numeric IPv4/IPv6 address or CIDR per line. Hostnames and URLs are rejected. Maximum 64 rules.");
            CloneBlockerUi.addTopSpace(this, bypassHelp, 8);
            bypassCard.addView(bypassHelp);
            bypassInput = multilineSetting(bypassCard);
            root.addView(bypassCard);

            LinearLayout actionCard = CloneBlockerUi.card(this);
            actionCard.addView(CloneBlockerUi.sectionTitle(this, "Apply"));
            LinearLayout actions = new LinearLayout(this);
            actions.setOrientation(LinearLayout.HORIZONTAL);
            CloneBlockerUi.addTopSpace(this, actions, 10);
            saveButton = CloneBlockerUi.button(this, "Save & connect");
            saveButton.setContentDescription("Validate, save, and apply SOCKS5 proxy settings");
            saveButton.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View view) {
                    saveAndApply();
                }
            });
            actions.addView(saveButton, new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            Button disconnect = CloneBlockerUi.button(this, "Disconnect");
            disconnect.setContentDescription("Disable and disconnect the SOCKS5 proxy");
            disconnect.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View view) {
                    if (ProxyController.disconnect(ProxySettingsActivity.this)) {
                        enabledSwitch.setChecked(false);
                        Toast.makeText(ProxySettingsActivity.this,
                                "Proxy disabled.", Toast.LENGTH_SHORT).show();
                    } else {
                        Toast.makeText(ProxySettingsActivity.this,
                                "Could not confirm the disabled setting. Check status; if Android VPN is inactive, direct traffic may continue.",
                                Toast.LENGTH_LONG).show();
                    }
                    refreshStatus();
                }
            });
            LinearLayout.LayoutParams disconnectParams = new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            disconnectParams.setMarginStart(CloneBlockerUi.dp(this, 8));
            actions.addView(disconnect, disconnectParams);
            actionCard.addView(actions);
            TextView disclosure = CloneBlockerUi.secondary(
                    this,
                    "Android allows only one VPN per user profile, so this can conflict with another VPN. SOCKS5 itself is not encrypted: the proxy path can observe authentication and destination metadata; HTTPS still protects request content. Bypass destinations, the proxy connection, and DNS needed to resolve a proxy hostname use the direct network. A numeric server address gives the strictest boundary.");
            CloneBlockerUi.addTopSpace(this, disclosure, 10);
            actionCard.addView(disclosure);
            root.addView(actionCard);

            enabledSwitch.setOnCheckedChangeListener(new CompoundButton.OnCheckedChangeListener() {
                @Override
                public void onCheckedChanged(CompoundButton buttonView, boolean checked) {
                    updateControlState();
                }
            });
            authSwitch.setOnCheckedChangeListener(new CompoundButton.OnCheckedChangeListener() {
                @Override
                public void onCheckedChanged(CompoundButton buttonView, boolean checked) {
                    updateControlState();
                }
            });
            populateStoredConfig();
            contentReady = true;
            refreshStatus();
        } catch (RuntimeException invalidLocalState) {
            contentReady = false;
            root.removeAllViews();
            root.addView(CloneBlockerUi.title(this, "SOCKS5 proxy"));
            LinearLayout review = CloneBlockerUi.card(this);
            review.addView(CloneBlockerUi.sectionTitle(this, "Proxy settings need review"));
            TextView message = CloneBlockerUi.body(
                    this,
                    "The local proxy configuration could not be displayed. Stored data was not reset. An active Android VPN stays fail-closed; without one, direct traffic may continue.");
            CloneBlockerUi.addTopSpace(this, message, 8);
            message.setTextColor(CloneBlockerUi.danger(this));
            review.addView(message);
            root.addView(review);
        }
    }

    private void populateStoredConfig() {
        ProxyConfigStore.Snapshot snapshot = ProxyConfigStore.snapshot(this);
        ProxyConfig config = snapshot.config;
        try {
            enabledSwitch.setChecked(snapshot.valid && config.enabled());
            hostInput.setText(snapshot.valid ? config.host() : "");
            portInput.setText(String.valueOf(
                    snapshot.valid ? config.port() : ProxyConfig.DEFAULT_PORT));
            authSwitch.setChecked(snapshot.valid && config.authEnabled());
            usernameInput.setText(snapshot.valid && config.authEnabled()
                    ? config.username() : "");
            savedPasswordAvailable = snapshot.valid
                    && config.authEnabled() && config.passwordLength() > 0;
            passwordInput.setText("");
            passwordInput.setHint(savedPasswordAvailable
                    ? "Saved — leave blank to keep" : "Password");
            bypassInput.setText(snapshot.valid ? config.bypassRules() : "");
            sensitiveFieldsCleared = false;
            updateControlState();
        } finally {
            snapshot.clearPassword();
        }
    }

    /** Rehydrates only encrypted-at-rest credentials after a pause cleared their view text. */
    private void restoreSensitiveFieldsIfNeeded() {
        if (!sensitiveFieldsCleared || usernameInput == null || passwordInput == null) {
            return;
        }
        ProxyConfigStore.Snapshot snapshot = ProxyConfigStore.snapshot(this);
        ProxyConfig config = snapshot.config;
        try {
            boolean savedAuth = authSwitch != null && authSwitch.isChecked()
                    && snapshot.valid && config.authEnabled();
            usernameInput.setText(savedAuth ? config.username() : "");
            savedPasswordAvailable = savedAuth && config.passwordLength() > 0;
            passwordInput.setText("");
            passwordInput.setHint(savedPasswordAvailable
                    ? "Saved — leave blank to keep" : "Password");
            sensitiveFieldsCleared = false;
        } finally {
            snapshot.clearPassword();
        }
    }

    private void saveAndApply() {
        char[] enteredPassword = passwordChars(passwordInput == null
                ? null : passwordInput.getText());
        char[] effectivePassword = enteredPassword;
        ProxyConfig existingConfig = null;
        ProxyConfigStore.Snapshot existing = null;
        ProxyConfig config = null;
        try {
            boolean authEnabled = authSwitch.isChecked();
            if (authEnabled && effectivePassword.length == 0) {
                existing = ProxyConfigStore.snapshot(this);
                existingConfig = existing.config;
                if (!existing.valid || !existingConfig.authEnabled()
                        || existingConfig.passwordLength() == 0) {
                    throw new IllegalArgumentException(
                            "Enter a password because no valid saved password is available.");
                }
                effectivePassword = existingConfig.passwordCopy();
            }
            int port = parsePort(portInput);
            config = ProxyConfig.checked(
                    enabledSwitch.isChecked(),
                    hostInput.getText().toString(),
                    port,
                    authEnabled,
                    usernameInput.getText().toString(),
                    effectivePassword,
                    bypassInput.getText().toString());
            if (!ProxyController.requestConnect(
                    this, config, VPN_PERMISSION_REQUEST)) {
                Toast.makeText(this,
                        "Could not confirm proxy persistence. Existing VPN state was not changed; if inactive, direct traffic may continue.",
                        Toast.LENGTH_LONG).show();
                return;
            }
            savedPasswordAvailable = config.authEnabled();
            passwordInput.setText("");
            passwordInput.setHint(savedPasswordAvailable
                    ? "Saved — leave blank to keep" : "Password");
            Toast.makeText(this,
                    config.enabled()
                            ? "Proxy settings saved. Complete Android VPN approval if shown."
                            : "Proxy settings saved and proxy disabled.",
                    Toast.LENGTH_SHORT).show();
            refreshStatus();
        } catch (IllegalArgumentException invalid) {
            String message = invalid.getMessage();
            Toast.makeText(this,
                    message == null ? "Check every proxy setting." : message,
                    Toast.LENGTH_LONG).show();
        } finally {
            Arrays.fill(enteredPassword, '\0');
            if (effectivePassword != enteredPassword) {
                Arrays.fill(effectivePassword, '\0');
            }
            if (config != null) {
                config.clearPassword();
            }
            if (existing != null) {
                existing.clearPassword();
            } else if (existingConfig != null) {
                existingConfig.clearPassword();
            }
        }
    }

    private void refreshStatus() {
        if (statusValue == null) {
            return;
        }
        // Observe before rendering. If the runtime changes during the full persisted-status
        // read, the next lightweight token poll will differ and refresh again instead of
        // accepting a newer token beside older visible text.
        observedRuntimeState = Socks5VpnService.runtimeState();
        String status = ProxyController.status(this);
        statusValue.setText(status);
        statusValue.setTextColor(status.startsWith("Paused")
                || status.startsWith("Unprotected")
                || status.startsWith("Unavailable")
                ? CloneBlockerUi.danger(this)
                : CloneBlockerUi.foreground(this));
    }

    private void startStatusPolling() {
        statusHandler.removeCallbacks(statusRefreshTask);
        statusPolling = true;
        if (!statusHandler.postDelayed(statusRefreshTask, STATUS_REFRESH_MILLIS)) {
            statusPolling = false;
            showStatusRefreshUnavailable();
        }
    }

    private void stopStatusPolling() {
        statusPolling = false;
        statusHandler.removeCallbacks(statusRefreshTask);
    }

    private void showStatusRefreshUnavailable() {
        if (statusValue == null) {
            return;
        }
        statusValue.setText(
                "Unavailable: live proxy status refresh stopped. Reopen this page before relying on proxy status.");
        statusValue.setTextColor(CloneBlockerUi.danger(this));
    }

    private void updateControlState() {
        if (authSwitch == null) {
            return;
        }
        boolean auth = authSwitch.isChecked();
        usernameInput.setEnabled(auth);
        passwordInput.setEnabled(auth);
        if (!auth) {
            usernameInput.setText("");
            passwordInput.setText("");
            savedPasswordAvailable = false;
            passwordInput.setHint("Password");
        }
        if (saveButton != null) {
            saveButton.setText(enabledSwitch.isChecked()
                    ? "Save & connect" : "Save disabled");
        }
    }

    private EditText textSetting(
            String title,
            String hint,
            int inputType,
            boolean selectAll,
            LinearLayout parent) {
        TextView label = CloneBlockerUi.body(this, title);
        CloneBlockerUi.addTopSpace(this, label, 10);
        parent.addView(label);
        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setSelectAllOnFocus(selectAll);
        input.setInputType(inputType);
        input.setHint(hint);
        input.setTextColor(CloneBlockerUi.foreground(this));
        input.setHintTextColor(CloneBlockerUi.secondary(this));
        input.setContentDescription(title + "; " + hint);
        parent.addView(input, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        return input;
    }

    private EditText multilineSetting(LinearLayout parent) {
        EditText input = new EditText(this);
        input.setMinLines(4);
        input.setMaxLines(10);
        input.setGravity(android.view.Gravity.TOP | android.view.Gravity.START);
        input.setInputType(InputType.TYPE_CLASS_TEXT
                | InputType.TYPE_TEXT_FLAG_MULTI_LINE
                | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        input.setHint("203.0.113.10\n10.0.0.0/8\n2001:db8::/32");
        input.setTextColor(CloneBlockerUi.foreground(this));
        input.setHintTextColor(CloneBlockerUi.secondary(this));
        input.setContentDescription("Ordered numeric proxy bypass rules, one per line");
        CloneBlockerUi.addTopSpace(this, input, 8);
        parent.addView(input, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        return input;
    }

    private Switch settingSwitch(String title, String summary, LinearLayout parent) {
        Switch control = new Switch(this);
        control.setText(title);
        control.setTextSize(16);
        control.setTextColor(CloneBlockerUi.foreground(this));
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

    private static int parsePort(EditText input) {
        String value = input == null ? "" : input.getText().toString().trim();
        if (value.length() == 0) {
            throw new IllegalArgumentException("SOCKS5 port is required.");
        }
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException invalid) {
            throw new IllegalArgumentException("SOCKS5 port must be a whole number.");
        }
    }

    private static char[] passwordChars(Editable value) {
        if (value == null || value.length() == 0) {
            return new char[0];
        }
        char[] copy = new char[value.length()];
        for (int index = 0; index < value.length(); index++) {
            copy[index] = value.charAt(index);
        }
        return copy;
    }
}
