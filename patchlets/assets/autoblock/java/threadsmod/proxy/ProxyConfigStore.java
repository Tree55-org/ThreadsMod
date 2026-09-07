package threadsmod.proxy;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.util.Arrays;
import java.util.Base64;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Atomic, fail-closed SOCKS5 configuration persistence with Keystore-encrypted credentials. */
public final class ProxyConfigStore {
    private static final String PREFS = "threadsmod_proxy";
    private static final int SCHEMA_VERSION = 1;
    private static final String KEYSTORE = "AndroidKeyStore";
    private static final String KEY_ALIAS = "threadsmod_proxy_config_aes_v1";
    private static final String CIPHER = "AES/GCM/NoPadding";
    private static final int GCM_TAG_BITS = 128;
    private static final int EXPECTED_IV_BYTES = 12;
    private static final int MAX_CIPHERTEXT_TEXT = 1024;
    private static final int MAX_IV_TEXT = 64;
    private static final Object LOCK = new Object();

    public static final String KEY_SCHEMA_VERSION = "threadsmod_proxy_schema_version";
    public static final String KEY_GENERATION = "threadsmod_proxy_generation";
    public static final String KEY_ENABLED = "threadsmod_proxy_enabled";
    public static final String KEY_HOST = "threadsmod_proxy_host";
    public static final String KEY_PORT = "threadsmod_proxy_port";
    public static final String KEY_AUTH_ENABLED = "threadsmod_proxy_auth_enabled";
    public static final String KEY_CREDENTIALS_CIPHERTEXT =
            "threadsmod_proxy_credentials_ciphertext";
    public static final String KEY_CREDENTIALS_IV = "threadsmod_proxy_credentials_iv";
    public static final String KEY_BYPASS_RULES = "threadsmod_proxy_bypass_rules_v1";
    public static final String KEY_FAIL_CLOSED = "threadsmod_proxy_fail_closed";

    private static final String[] OWNED_KEYS = new String[] {
            KEY_SCHEMA_VERSION,
            KEY_GENERATION,
            KEY_ENABLED,
            KEY_HOST,
            KEY_PORT,
            KEY_AUTH_ENABLED,
            KEY_CREDENTIALS_CIPHERTEXT,
            KEY_CREDENTIALS_IV,
            KEY_BYPASS_RULES,
            KEY_FAIL_CLOSED
    };

    private static boolean persistenceUncertain;

    private ProxyConfigStore() {}

    /** One bounded read result. Invalid or uncertain state always requests fail-closed routing. */
    public static final class Snapshot {
        public final boolean valid;
        public final boolean persistenceUncertain;
        public final boolean enabledRequested;
        public final String state;
        public final ProxyConfig config;

        Snapshot(
                boolean valid,
                boolean persistenceUncertain,
                boolean enabledRequested,
                String state,
                ProxyConfig config) {
            this.valid = valid;
            this.persistenceUncertain = persistenceUncertain;
            this.enabledRequested = enabledRequested;
            this.state = state;
            this.config = config;
        }

        public void clearPassword() {
            if (config != null) {
                config.clearPassword();
            }
        }
    }

    /** Missing state is a valid disabled default; partial, mistyped, or unreadable state is not. */
    public static Snapshot snapshot(Context context) {
        if (context == null) {
            return invalidSnapshot(true, "context_missing", false);
        }
        synchronized (LOCK) {
            if (persistenceUncertain) {
                return invalidSnapshot(true, "persistence_uncertain", true);
            }
            try {
                return readSnapshot(readAll(preferences(context)));
            } catch (Exception unreadable) {
                persistenceUncertain = true;
                return invalidSnapshot(true, "read_failure", true);
            }
        }
    }

    public static boolean isValid(Context context) {
        Snapshot value = snapshot(context);
        try {
            return value.valid;
        } finally {
            value.clearPassword();
        }
    }

    /**
     * Commits one complete validated snapshot. A failed commit restores the exact prior owned-key
     * types when possible; uncertain process-local state remains latched until a later full save.
     */
    public static boolean save(Context context, ProxyConfig config) {
        if (context == null || config == null) {
            return false;
        }
        char[] validationPassword = config.passwordCopy();
        final ProxyConfig validated;
        try {
            validated = ProxyConfig.checked(
                    config.enabled(), config.host(), config.port(), config.authEnabled(),
                    config.username(), validationPassword, config.bypassRules());
        } catch (IllegalArgumentException invalid) {
            return false;
        } finally {
            Arrays.fill(validationPassword, '\0');
        }

        synchronized (LOCK) {
            Map<String, ?> before;
            boolean wasUncertain = persistenceUncertain;
            long generation;
            try {
                SharedPreferences preferences = preferences(context);
                before = readAll(preferences);
                generation = nextGeneration(before);
                Secret secret = validated.authEnabled()
                        ? encrypt(validated, generation) : Secret.empty();
                try {
                    // Android may update its process-local map even when commit returns false.
                    persistenceUncertain = true;
                    SharedPreferences.Editor editor = preferences.edit()
                            .putInt(KEY_SCHEMA_VERSION, SCHEMA_VERSION)
                            .putLong(KEY_GENERATION, generation)
                            .putBoolean(KEY_ENABLED, validated.enabled())
                            .putString(KEY_HOST, validated.host())
                            .putInt(KEY_PORT, validated.port())
                            .putBoolean(KEY_AUTH_ENABLED, validated.authEnabled())
                            .putString(KEY_BYPASS_RULES, validated.bypassRules())
                            .putBoolean(KEY_FAIL_CLOSED, true);
                    if (validated.authEnabled()) {
                        editor.putString(KEY_CREDENTIALS_CIPHERTEXT, secret.ciphertext)
                                .putString(KEY_CREDENTIALS_IV, secret.iv);
                    } else {
                        editor.remove(KEY_CREDENTIALS_CIPHERTEXT)
                                .remove(KEY_CREDENTIALS_IV);
                    }
                    if (editor.commit()) {
                        persistenceUncertain = false;
                        return true;
                    }
                    SharedPreferences.Editor restore = preferences.edit();
                    for (String key : OWNED_KEYS) {
                        restoreValue(restore, before, key);
                    }
                    if (restore.commit()) {
                        persistenceUncertain = wasUncertain;
                    }
                    return false;
                } finally {
                    secret.clear();
                }
            } catch (Exception persistenceFailure) {
                persistenceUncertain = true;
                return false;
            } finally {
                validated.clearPassword();
            }
        }
    }

    private static Snapshot readSnapshot(Map<String, ?> values)
            throws GeneralSecurityException {
        boolean any = false;
        for (String key : OWNED_KEYS) {
            any |= values.containsKey(key);
        }
        if (!any) {
            return new Snapshot(true, false, false, "disabled_default", ProxyConfig.defaults());
        }
        if (!(values.get(KEY_SCHEMA_VERSION) instanceof Integer)
                || !(values.get(KEY_GENERATION) instanceof Long)
                || !(values.get(KEY_ENABLED) instanceof Boolean)
                || !(values.get(KEY_HOST) instanceof String)
                || !(values.get(KEY_PORT) instanceof Integer)
                || !(values.get(KEY_AUTH_ENABLED) instanceof Boolean)
                || !(values.get(KEY_BYPASS_RULES) instanceof String)
                || !(values.get(KEY_FAIL_CLOSED) instanceof Boolean)) {
            return invalidSnapshot(true, "invalid_types", false);
        }
        int schema = ((Integer) values.get(KEY_SCHEMA_VERSION)).intValue();
        long generation = ((Long) values.get(KEY_GENERATION)).longValue();
        boolean enabled = ((Boolean) values.get(KEY_ENABLED)).booleanValue();
        String host = (String) values.get(KEY_HOST);
        int port = ((Integer) values.get(KEY_PORT)).intValue();
        boolean authEnabled = ((Boolean) values.get(KEY_AUTH_ENABLED)).booleanValue();
        String bypass = (String) values.get(KEY_BYPASS_RULES);
        boolean failClosed = ((Boolean) values.get(KEY_FAIL_CLOSED)).booleanValue();
        if (schema != SCHEMA_VERSION || generation < 1L || !failClosed) {
            return invalidSnapshot(true, "invalid_header", false);
        }
        if (host.length() > ProxyConfig.MAX_HOST_ASCII
                || bypass.length() > ProxyBypassPolicy.MAX_TEXT_UTF16) {
            return invalidSnapshot(true, "oversized_values", false);
        }

        Credentials credentials = Credentials.empty();
        try {
            if (authEnabled) {
                if (!(values.get(KEY_CREDENTIALS_CIPHERTEXT) instanceof String)
                        || !(values.get(KEY_CREDENTIALS_IV) instanceof String)) {
                    return invalidSnapshot(true, "secret_missing", false);
                }
                String ciphertext = (String) values.get(KEY_CREDENTIALS_CIPHERTEXT);
                String iv = (String) values.get(KEY_CREDENTIALS_IV);
                if (ciphertext.length() == 0 || ciphertext.length() > MAX_CIPHERTEXT_TEXT
                        || iv.length() == 0 || iv.length() > MAX_IV_TEXT) {
                    return invalidSnapshot(true, "secret_invalid", false);
                }
                credentials = decrypt(
                        ciphertext, iv, schema, generation, enabled, host, port,
                        authEnabled, bypass, failClosed);
            } else if (values.containsKey(KEY_CREDENTIALS_CIPHERTEXT)
                    || values.containsKey(KEY_CREDENTIALS_IV)) {
                return invalidSnapshot(true, "unexpected_secret", false);
            }
            ProxyConfig config = ProxyConfig.checked(
                    enabled, host, port, authEnabled,
                    credentials.username, credentials.password, bypass);
            return new Snapshot(true, false, enabled, enabled ? "enabled" : "disabled", config);
        } catch (IllegalArgumentException invalid) {
            return invalidSnapshot(true, "invalid_values", false);
        } finally {
            credentials.clear();
        }
    }

    private static Snapshot invalidSnapshot(
            boolean enabledRequested, String state, boolean uncertain) {
        return new Snapshot(false, uncertain, enabledRequested, state, ProxyConfig.defaults());
    }

    private static long nextGeneration(Map<String, ?> values) {
        Object stored = values.get(KEY_GENERATION);
        if (stored instanceof Long) {
            long prior = ((Long) stored).longValue();
            if (prior > 0L && prior < Long.MAX_VALUE) {
                return prior + 1L;
            }
            if (prior == Long.MAX_VALUE) {
                throw new IllegalStateException("Proxy configuration generation is exhausted.");
            }
        }
        return 1L;
    }

    private static Secret encrypt(ProxyConfig config, long generation)
            throws GeneralSecurityException {
        byte[] plaintext = credentialBytes(config);
        byte[] aad = aad(
                SCHEMA_VERSION, generation, config.enabled(), config.host(), config.port(),
                config.authEnabled(), config.bypassRules(), true);
        try {
            Cipher cipher = Cipher.getInstance(CIPHER);
            cipher.init(Cipher.ENCRYPT_MODE, key());
            cipher.updateAAD(aad);
            byte[] encrypted = cipher.doFinal(plaintext);
            byte[] iv = cipher.getIV();
            if (iv == null || iv.length != EXPECTED_IV_BYTES) {
                Arrays.fill(encrypted, (byte) 0);
                throw new GeneralSecurityException("Unexpected GCM IV length.");
            }
            try {
                return new Secret(
                        Base64.getEncoder().withoutPadding().encodeToString(encrypted),
                        Base64.getEncoder().withoutPadding().encodeToString(iv));
            } finally {
                Arrays.fill(encrypted, (byte) 0);
                Arrays.fill(iv, (byte) 0);
            }
        } finally {
            Arrays.fill(plaintext, (byte) 0);
            Arrays.fill(aad, (byte) 0);
        }
    }

    private static Credentials decrypt(
            String ciphertext,
            String iv,
            int schema,
            long generation,
            boolean enabled,
            String host,
            int port,
            boolean authEnabled,
            String bypass,
            boolean failClosed) throws GeneralSecurityException {
        final byte[] encrypted;
        final byte[] ivBytes;
        try {
            encrypted = Base64.getDecoder().decode(ciphertext);
            ivBytes = Base64.getDecoder().decode(iv);
        } catch (IllegalArgumentException invalid) {
            throw new GeneralSecurityException("Stored proxy secret encoding is invalid.");
        }
        if (ivBytes.length != EXPECTED_IV_BYTES || encrypted.length < 20
                || encrypted.length > (ProxyConfig.MAX_AUTH_BYTES * 2) + 18) {
            Arrays.fill(encrypted, (byte) 0);
            Arrays.fill(ivBytes, (byte) 0);
            throw new GeneralSecurityException("Stored proxy secret length is invalid.");
        }
        byte[] aad = aad(
                schema, generation, enabled, host, port, authEnabled, bypass, failClosed);
        byte[] plaintext = null;
        try {
            Cipher cipher = Cipher.getInstance(CIPHER);
            cipher.init(Cipher.DECRYPT_MODE, key(),
                    new GCMParameterSpec(GCM_TAG_BITS, ivBytes));
            cipher.updateAAD(aad);
            plaintext = cipher.doFinal(encrypted);
            return credentialsFromBytes(plaintext);
        } finally {
            Arrays.fill(encrypted, (byte) 0);
            Arrays.fill(ivBytes, (byte) 0);
            Arrays.fill(aad, (byte) 0);
            if (plaintext != null) {
                Arrays.fill(plaintext, (byte) 0);
            }
        }
    }

    private static SecretKey key() throws GeneralSecurityException {
        KeyStore store = KeyStore.getInstance(KEYSTORE);
        try {
            store.load(null);
        } catch (Exception unavailable) {
            throw new GeneralSecurityException("Android Keystore is unavailable.");
        }
        java.security.Key existing = store.getKey(KEY_ALIAS, null);
        if (existing instanceof SecretKey) {
            return (SecretKey) existing;
        }
        KeyGenerator generator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES, KEYSTORE);
        generator.init(new KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build());
        return generator.generateKey();
    }

    private static byte[] aad(
            int schema,
            long generation,
            boolean enabled,
            String host,
            int port,
            boolean authEnabled,
            String bypass,
            boolean failClosed) {
        StringBuilder value = new StringBuilder(128 + bypass.length());
        append(value, String.valueOf(schema));
        append(value, String.valueOf(generation));
        append(value, enabled ? "1" : "0");
        append(value, host);
        append(value, String.valueOf(port));
        append(value, authEnabled ? "1" : "0");
        append(value, bypass);
        append(value, failClosed ? "1" : "0");
        return value.toString().getBytes(StandardCharsets.UTF_8);
    }

    private static void append(StringBuilder output, String value) {
        output.append(value.length()).append(':').append(value);
    }

    private static byte[] credentialBytes(ProxyConfig config)
            throws GeneralSecurityException {
        String username = config.username();
        char[] password = config.passwordCopy();
        byte[] result = new byte[2 + username.length() + password.length];
        try {
            if (username.length() < 1 || username.length() > ProxyConfig.MAX_AUTH_BYTES
                    || password.length < 1 || password.length > ProxyConfig.MAX_AUTH_BYTES) {
                throw new GeneralSecurityException("Proxy credential length is invalid.");
            }
            result[0] = (byte) username.length();
            for (int index = 0; index < username.length(); index++) {
                char next = username.charAt(index);
                if (next < 0x20 || next > 0x7e) {
                    throw new GeneralSecurityException("Proxy credential encoding is invalid.");
                }
                result[index + 1] = (byte) next;
            }
            int passwordLengthIndex = username.length() + 1;
            result[passwordLengthIndex] = (byte) password.length;
            for (int index = 0; index < password.length; index++) {
                char next = password[index];
                if (next < 0x20 || next > 0x7e) {
                    throw new GeneralSecurityException("Proxy credential encoding is invalid.");
                }
                result[passwordLengthIndex + 1 + index] = (byte) next;
            }
            return result;
        } catch (GeneralSecurityException invalid) {
            Arrays.fill(result, (byte) 0);
            throw invalid;
        } finally {
            Arrays.fill(password, '\0');
        }
    }

    private static Credentials credentialsFromBytes(byte[] value)
            throws GeneralSecurityException {
        if (value.length < 4 || value.length > (ProxyConfig.MAX_AUTH_BYTES * 2) + 2) {
            throw new GeneralSecurityException("Stored proxy credential length is invalid.");
        }
        int usernameLength = value[0] & 0xff;
        if (usernameLength < 1 || usernameLength > ProxyConfig.MAX_AUTH_BYTES
                || usernameLength + 2 > value.length) {
            throw new GeneralSecurityException("Stored proxy credential structure is invalid.");
        }
        int passwordLengthIndex = usernameLength + 1;
        int passwordLength = value[passwordLengthIndex] & 0xff;
        if (passwordLength < 1 || passwordLength > ProxyConfig.MAX_AUTH_BYTES
                || passwordLengthIndex + 1 + passwordLength != value.length) {
            throw new GeneralSecurityException("Stored proxy credential structure is invalid.");
        }
        char[] usernameChars = new char[usernameLength];
        char[] password = new char[passwordLength];
        try {
            for (int index = 0; index < usernameLength; index++) {
                int next = value[index + 1] & 0xff;
                if (next < 0x20 || next > 0x7e) {
                    throw new GeneralSecurityException("Stored proxy credential is invalid.");
                }
                usernameChars[index] = (char) next;
            }
            for (int index = 0; index < passwordLength; index++) {
                int next = value[passwordLengthIndex + 1 + index] & 0xff;
                if (next < 0x20 || next > 0x7e) {
                    throw new GeneralSecurityException("Stored proxy credential is invalid.");
                }
                password[index] = (char) next;
            }
            return new Credentials(new String(usernameChars), password);
        } catch (GeneralSecurityException invalid) {
            Arrays.fill(password, '\0');
            throw invalid;
        } finally {
            Arrays.fill(usernameChars, '\0');
            Arrays.fill(password, '\0');
        }
    }

    private static SharedPreferences preferences(Context context) {
        return context.getApplicationContext()
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static Map<String, ?> readAll(SharedPreferences preferences) {
        Map<String, ?> values = preferences.getAll();
        if (values == null) {
            throw new IllegalStateException("Proxy preferences returned no snapshot.");
        }
        return values;
    }

    private static void restoreValue(
            SharedPreferences.Editor editor, Map<String, ?> values, String key) {
        if (!values.containsKey(key)) {
            editor.remove(key);
            return;
        }
        Object value = values.get(key);
        if (value instanceof Integer) {
            editor.putInt(key, ((Integer) value).intValue());
        } else if (value instanceof String) {
            editor.putString(key, (String) value);
        } else if (value instanceof Boolean) {
            editor.putBoolean(key, ((Boolean) value).booleanValue());
        } else if (value instanceof Long) {
            editor.putLong(key, ((Long) value).longValue());
        } else if (value instanceof Float) {
            editor.putFloat(key, ((Float) value).floatValue());
        } else if (value instanceof Set<?>) {
            HashSet<String> copy = new HashSet<String>();
            for (Object member : (Set<?>) value) {
                if (!(member instanceof String)) {
                    editor.remove(key);
                    return;
                }
                copy.add((String) member);
            }
            editor.putStringSet(key, copy);
        } else {
            editor.remove(key);
        }
    }

    private static final class Credentials {
        final String username;
        final char[] password;

        Credentials(String username, char[] password) {
            this.username = username;
            this.password = password.clone();
        }

        static Credentials empty() {
            return new Credentials("", new char[0]);
        }

        void clear() {
            Arrays.fill(password, '\0');
        }
    }

    private static final class Secret {
        final String ciphertext;
        final String iv;

        Secret(String ciphertext, String iv) {
            this.ciphertext = ciphertext;
            this.iv = iv;
        }

        static Secret empty() {
            return new Secret("", "");
        }

        void clear() {
            // Encoded ciphertext and IV are not plaintext credentials. They are immutable Strings.
        }
    }
}
