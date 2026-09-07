package threadsmod.reporting;

/** Immutable host-class-free context for one explicitly initiated report. */
public final class ReportRequest {
    private static final int MAX_ITEM_KEY = 128;
    private static final int MAX_SHORTCODE = 64;
    private static final String NO_TEXT_EXCERPT = "(no text in this post)";

    private final String itemKey;
    private final String profileUsername;
    private final String profileId;
    private final String postContent;
    private final String displayName;
    private final String permalink;

    public ReportRequest(
            String profileUsername,
            String profileId,
            String postContent,
            String displayName,
            String permalink) {
        this("", profileUsername, profileId, postContent, displayName, permalink);
    }

    public ReportRequest(
            String itemKey,
            String profileUsername,
            String profileId,
            String postContent) {
        this(itemKey, profileUsername, profileId, postContent, "", "");
    }

    public ReportRequest(
            String itemKey,
            String profileUsername,
            String profileId,
            String postContent,
            String displayName,
            String permalink) {
        this.itemKey = ReportValues.cleanText(itemKey, MAX_ITEM_KEY);
        this.profileUsername = ReportValues.normalizeUsername(profileUsername);
        this.profileId = ReportValues.isNumericId(profileId) ? profileId : "";
        this.postContent = ReportValues.cleanText(
                postContent, ReportValues.MAX_POST_CONTENT);
        this.displayName = ReportValues.cleanText(
                displayName, ReportValues.MAX_DISPLAY_NAME);
        this.permalink = ReportValues.httpsThreadsPermalink(
                permalink, this.profileUsername);
    }

    public ReportRequest(String profileUsername, String profileId, String postContent) {
        this("", profileUsername, profileId, postContent, "", "");
    }

    /** Local immutable row identity; deliberately excluded from the wire payload. */
    public String getItemKey() {
        return itemKey;
    }

    public String getProfileUsername() {
        return profileUsername;
    }

    public String getProfileId() {
        return profileId;
    }

    public String getPostContent() {
        return postContent;
    }

    public String getDisplayName() {
        return displayName;
    }

    public String getPermalink() {
        return permalink;
    }

    public boolean isValid() {
        return profileUsername.length() > 0
                && ReportValues.isNumericId(profileId)
                && postContent.length() > 0;
    }

    /** New explicit reports require immutable post evidence; legacy stored rows may omit it. */
    public boolean isValidForNewQueue() {
        return isValid() && permalink.length() > 0;
    }

    public boolean isViewer(String viewerId) {
        return ReportValues.isNumericId(viewerId) && profileId.equals(viewerId);
    }

    /**
     * Constructs the native code-first canonical Threads URL from the exact-SHA media shortcode
     * accessor, falling back to the row permalink only when no valid code exists. Both paths are
     * normalized by the shared strict URL validator before becoming report authority.
     */
    public static String resolveHostPermalink(
            String profileUsername, String candidate, String shortcode) {
        String username = ReportValues.normalizeUsername(profileUsername);
        if (username.length() > 0 && shortcode != null
                && shortcode.length() > 0 && shortcode.length() <= MAX_SHORTCODE) {
            boolean validShortcode = true;
            for (int i = 0; i < shortcode.length(); i++) {
                char c = shortcode.charAt(i);
                if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                        || (c >= '0' && c <= '9') || c == '_' || c == '-')) {
                    validShortcode = false;
                    break;
                }
            }
            if (validShortcode) {
                String fromCode = ReportValues.httpsThreadsPermalink(
                        "https://www.threads.com/@" + username + "/post/" + shortcode,
                        username);
                if (fromCode.length() > 0) {
                    return fromCode;
                }
            }
        }
        return ReportValues.httpsThreadsPermalink(candidate, username);
    }

    /** Supplies explicit truthful evidence for a media post whose row has no textual caption. */
    public static String resolveHostExcerpt(String candidate) {
        String excerpt = ReportValues.cleanText(candidate, ReportValues.MAX_POST_CONTENT);
        return excerpt.length() == 0 ? NO_TEXT_EXCERPT : excerpt;
    }

    String targetKey() {
        return "threads:" + profileId;
    }
}
