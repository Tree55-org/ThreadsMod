package threadsmod.reporting;

/** Host-JVM checks for identity, Unicode-safe trimming, and row-bound post permalinks. */
public final class ReportValuesHarness {
    private ReportValuesHarness() {}

    public static void main(String[] args) {
        ReportRequest valid = new ReportRequest(
                "media-42", "@Profile.Name", "1234", "  visible post  ");
        require(valid.isValid(), "valid required fields");
        require("profile.name".equals(valid.getProfileUsername()), "username normalized");
        require("1234".equals(valid.getProfileId()), "numeric id retained");
        require("visible post".equals(valid.getPostContent()), "post trimmed");
        require("media-42".equals(valid.getItemKey()), "local row identity retained");
        require(!valid.isValidForNewQueue(), "legacy empty-link row is not newly queued");

        ReportRequest rowBound = new ReportRequest(
                "media-43",
                "@username",
                "5678",
                "reported post",
                "Profile display",
                "https://www.threads.com/@username/post/shortcode");
        require(rowBound.isValidForNewQueue(), "user-vector row is queueable");
        require("media-43".equals(rowBound.getItemKey()), "six-string row key retained");
        require("Profile display".equals(rowBound.getDisplayName()),
                "six-string display name retained");
        require("https://www.threads.com/@username/post/shortcode".equals(
                rowBound.getPermalink()), "user-vector URL retained canonically");

        require(!new ReportRequest("user", "123", "post").isValid(), "short id rejected");
        require(!new ReportRequest("user", "0001", "post").isValid(),
                "leading-zero id rejected");
        require(!new ReportRequest("user", "0000", "post").isValid(),
                "all-zero id rejected");
        require(!new ReportRequest("bad user", "1234", "post").isValid(),
                "invalid username rejected");
        require(!new ReportRequest("user", "1234", " \n\t ").isValid(),
                "empty trimmed excerpt rejected");

        StringBuilder source = new StringBuilder();
        for (int i = 0; i < 279; i++) {
            source.append('a');
        }
        source.appendCodePoint(0x1F600);
        source.append('z');
        ReportRequest bounded = new ReportRequest("user", "1234", source.toString());
        require(bounded.getPostContent().length() == 279, "no dangling surrogate at boundary");
        require(!Character.isHighSurrogate(
                bounded.getPostContent().charAt(bounded.getPostContent().length() - 1)),
                "surrogate pair is never split");

        StringBuilder pairFit = new StringBuilder();
        for (int i = 0; i < 278; i++) {
            pairFit.append('b');
        }
        pairFit.appendCodePoint(0x1F600);
        pairFit.append('z');
        ReportRequest exactlyBounded = new ReportRequest("user", "1234", pairFit.toString());
        require(exactlyBounded.getPostContent().length() == 280, "full pair fits exact bound");
        require(Character.isLowSurrogate(exactlyBounded.getPostContent().charAt(279)),
                "complete surrogate pair retained");

        require("https://www.threads.com/@user/post/Abc_9-z".equals(
                ReportValues.httpsThreadsPermalink(
                        "https://www.threads.com/@user/post/Abc_9-z", "user")),
                "current Threads link allowed");
        require("https://www.threads.com/@ryanlee256627/post/Dcu2KS6kR52".equals(
                ReportValues.httpsThreadsPermalink(
                        "https://www.threads.com/@ryanlee256627/post/Dcu2KS6kR52",
                        "ryanlee256627")),
                "reported missing-link regression vector retained");
        require("https://www.threads.com/@user/post/legacy".equals(
                ReportValues.httpsThreadsPermalink(
                        "https://www.threads.net/@user/post/legacy", "@USER")),
                "legacy Threads host canonicalized to current host");
        require(ReportValues.httpsThreadsPermalink(
                "https://example.com/@user/post/abc", "user").length() == 0,
                "foreign link rejected");
        require(ReportValues.httpsThreadsPermalink(
                "https://user:secret@www.threads.com/@user/post/abc", "user").length() == 0,
                "userinfo rejected");
        require(ReportValues.httpsThreadsPermalink(
                "https://www.threads.com:443/@user/post/abc", "user").length() == 0,
                "explicit port rejected");
        require(ReportValues.httpsThreadsPermalink(
                "https://www.threads.com:/@user/post/abc", "user").length() == 0,
                "empty explicit port rejected");
        require(ReportValues.httpsThreadsPermalink(
                "https://www.threads.com/@user/post/abc?access_token=raw", "user").length() == 0,
                "query rejected");
        require(ReportValues.httpsThreadsPermalink(
                "https://www.threads.com/@user/post/abc#token", "user").length() == 0,
                "fragment rejected");
        require(ReportValues.httpsThreadsPermalink(
                "https://threads.com/@user/post/abc", "user").length() == 0,
                "bare host rejected");
        require(ReportValues.httpsThreadsPermalink(
                "https://evil.www.threads.com/@user/post/abc", "user").length() == 0,
                "host suffix trick rejected");
        require(ReportValues.httpsThreadsPermalink(
                "http://www.threads.com/@user/post/abc", "user").length() == 0,
                "non-HTTPS link rejected");
        require(ReportValues.httpsThreadsPermalink(
                "https://www.threads.com/@other/post/abc", "user").length() == 0,
                "mismatched username rejected");
        require(ReportValues.httpsThreadsPermalink(
                "https://www.threads.com/@%75ser/post/abc", "user").length() == 0,
                "encoded username rejected");
        require(ReportValues.httpsThreadsPermalink(
                "https://www.threads.com/@user/post/%61bc", "user").length() == 0,
                "encoded shortcode rejected");
        require(ReportValues.httpsThreadsPermalink(
                "https://www.threads.com/@user/post/abc/extra", "user").length() == 0,
                "extra path segment rejected");
        require(ReportValues.httpsThreadsPermalink(
                "https://www.threads.com/@User/post/abc", "user").length() == 0,
                "noncanonical path username rejected");
        require(ReportValues.httpsThreadsPermalink(
                " https://www.threads.com/@user/post/abc", "user").length() == 0,
                "surrounding whitespace rejected");

        StringBuilder exactPermalink = new StringBuilder(
                "https://www.threads.com/@user/post/");
        while (exactPermalink.length() < ReportValues.MAX_PERMALINK) {
            exactPermalink.append('a');
        }
        String acceptedMaximumPermalink = exactPermalink.toString();
        require(acceptedMaximumPermalink.length() == 300,
                "maximum permalink vector is exactly 300 units");
        require(acceptedMaximumPermalink.equals(ReportValues.httpsThreadsPermalink(
                acceptedMaximumPermalink, "user")),
                "canonical 300-unit permalink accepted");
        String rejectedOverlongPermalink = acceptedMaximumPermalink + "b";
        require(rejectedOverlongPermalink.length() == 301,
                "overlong permalink vector is exactly 301 units");
        require(ReportValues.httpsThreadsPermalink(
                rejectedOverlongPermalink, "user").length() == 0,
                "canonical 301-unit permalink rejected");

        ReportRequest mismatch = new ReportRequest(
                "media-44", "right.user", "6789", "reported post", "",
                "https://www.threads.com/@wrong.user/post/abc");
        require(mismatch.isValid(), "mismatch still decodes as legacy-compatible identity");
        require(!mismatch.isValidForNewQueue(), "mismatched permalink cannot enter new queue");

        require("https://www.threads.com/@user/post/Code_9-z".equals(
                ReportRequest.resolveHostPermalink(
                        "@USER",
                        "https://www.threads.net/@user/post/older",
                        "Code_9-z")),
                "exact media code is the native first-choice permalink source");
        require("https://www.threads.com/@user/post/direct".equals(
                ReportRequest.resolveHostPermalink(
                        "user",
                        "https://www.threads.net/@user/post/direct",
                        "bad/code")),
                "strict canonical row permalink remains the invalid-code fallback");
        require(ReportRequest.resolveHostPermalink(
                "user", "https://example.com/@user/post/no", "bad/code").length() == 0,
                "invalid code and invalid row permalink fail closed");
        require(ReportRequest.resolveHostPermalink(
                "bad user", "https://www.threads.com/@user/post/no", "GoodCode").length() == 0,
                "fallback cannot bypass username validation");
        require("trimmed host text".equals(
                ReportRequest.resolveHostExcerpt("  trimmed host text  ")),
                "host caption is bounded and trimmed");
        require("(no text in this post)".equals(
                ReportRequest.resolveHostExcerpt(" \n\t ")),
                "captionless media receives the extension-compatible truthful excerpt");

        System.out.println("PASS report required=true canonical-id=true utf16=280 username=true link-strict=true link-max=300 code-fallback=true empty-caption=true");
    }

    private static void require(boolean value, String label) {
        if (!value) {
            throw new AssertionError(label);
        }
    }
}
