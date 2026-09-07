package threadsmod.inlinecontrol;

/** Immutable row identity plus an opaque, transient hint for one inline action. */
public final class InlineBlockRequest {
    private static final int MAX_MEDIA_KEY = 128;
    private static final int MAX_LABEL = 80;

    private final String mediaKey;
    private final String authorId;
    private final String label;
    private final Object resolvedAuthorModel;
    private final Object resolvedMediaModel;

    public InlineBlockRequest(String mediaKey, String authorId, String label) {
        this(mediaKey, authorId, label, null, null);
    }

    public InlineBlockRequest(
            String mediaKey,
            String authorId,
            String label,
            Object resolvedAuthorModel) {
        this(mediaKey, authorId, label, resolvedAuthorModel, null);
    }

    private InlineBlockRequest(
            String mediaKey,
            String authorId,
            String label,
            Object resolvedAuthorModel,
            Object resolvedMediaModel) {
        this.mediaKey = cleanText(mediaKey, MAX_MEDIA_KEY);
        this.authorId = isNumericId(authorId) ? authorId : "";
        this.label = cleanText(label, MAX_LABEL);
        this.resolvedAuthorModel = resolvedAuthorModel;
        this.resolvedMediaModel = resolvedMediaModel;
    }

    /** Builds the immutable identity captured by the exact-SHA native row rewrite. */
    public static InlineBlockRequest createHostBound(
            String mediaKey,
            String authorId,
            String username,
            Object resolvedAuthorModel,
            Object resolvedMediaModel) {
        String cleanUsername = cleanText(username, MAX_LABEL - 1);
        String displayLabel = cleanUsername.length() == 0
                ? "" : (cleanUsername.startsWith("@") ? cleanUsername : "@" + cleanUsername);
        return new InlineBlockRequest(
                mediaKey, authorId, displayLabel, resolvedAuthorModel, resolvedMediaModel);
    }

    public String getMediaKey() {
        return mediaKey;
    }

    public String getAuthorId() {
        return authorId;
    }

    public String getLabel() {
        return label;
    }

    /**
     * Returns only the exact host row model captured by the SHA-bound adapter.
     * Stable Java deliberately treats it as Object and never reflects on it.
     */
    public Object getResolvedAuthorModel() {
        return resolvedAuthorModel;
    }

    /** Returns only the exact host media model captured with the same row identity. */
    public Object getResolvedMediaModel() {
        return resolvedMediaModel;
    }

    public boolean isValid() {
        return mediaKey.length() > 0 && isNumericId(authorId);
    }

    public boolean hasMediaKey(String currentMediaKey) {
        return mediaKey.equals(cleanText(currentMediaKey, MAX_MEDIA_KEY));
    }

    public String operationKey() {
        return mediaKey + "\n" + authorId;
    }

    @Override
    public boolean equals(Object other) {
        if (this == other) {
            return true;
        }
        if (!(other instanceof InlineBlockRequest)) {
            return false;
        }
        InlineBlockRequest request = (InlineBlockRequest) other;
        return mediaKey.equals(request.mediaKey) && authorId.equals(request.authorId);
    }

    @Override
    public int hashCode() {
        return 31 * mediaKey.hashCode() + authorId.hashCode();
    }

    @Override
    public String toString() {
        return "InlineBlockRequest{" + mediaKey + ", author=" + authorId + "}";
    }

    public static boolean isNumericId(String value) {
        if (value == null || value.length() < 4 || value.length() > 24
                || value.charAt(0) == '0') {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c < '0' || c > '9') {
                return false;
            }
        }
        return true;
    }

    private static String cleanText(String value, int maxLength) {
        if (value == null) {
            return "";
        }
        StringBuilder clean = new StringBuilder();
        for (int i = 0; i < value.length() && clean.length() < maxLength; i++) {
            char c = value.charAt(i);
            if (c >= 32 && c != 127) {
                clean.append(c);
            }
        }
        return clean.toString().trim();
    }
}
