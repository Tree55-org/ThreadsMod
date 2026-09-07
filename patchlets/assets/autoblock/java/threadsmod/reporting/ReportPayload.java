package threadsmod.reporting;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;

/** Validated wire payload. It has deliberately no viewer-ID field. */
public final class ReportPayload {
    public static final String REASON_REDBULL = "redbull";
    public static final String REASON_CLONE = "clone";
    public static final String REASON_IMPERSONATION = "impersonation";
    public static final String REASON_SCAM = "scam";
    public static final String REASON_HARASSMENT = "harassment";
    public static final String REASON_SPAM = "spam";
    public static final String REASON_OTHER = "other";

    private final String pseudonym;
    private final ReportRequest request;
    private final String reason;
    private final String note;
    private final String language;
    private final String timeZone;

    private ReportPayload(
            String pseudonym,
            ReportRequest request,
            String reason,
            String note,
            String language,
            String timeZone) {
        this.pseudonym = ReportValues.isPseudonym(pseudonym) ? pseudonym : "";
        this.request = request;
        this.reason = isReason(reason) ? reason : "";
        this.note = ReportValues.cleanText(note, ReportValues.MAX_NOTE);
        this.language = ReportValues.cleanText(language, ReportValues.MAX_LANGUAGE);
        this.timeZone = ReportValues.cleanText(timeZone, ReportValues.MAX_TIME_ZONE);
    }

    static ReportPayload create(
            String pseudonym,
            ReportRequest request,
            String reason,
            String note,
            String language,
            String timeZone) {
        return new ReportPayload(pseudonym, request, reason, note, language, timeZone);
    }

    public boolean isValid() {
        return pseudonym.length() > 0 && request != null && request.isValid()
                && reason.length() > 0;
    }

    public String getTargetId() {
        return request == null ? "" : request.getProfileId();
    }

    public String getTargetUsername() {
        return request == null ? "" : request.getProfileUsername();
    }

    public String getReason() {
        return reason;
    }

    public String getPostContent() {
        return request == null ? "" : request.getPostContent();
    }

    String getPseudonym() {
        return pseudonym;
    }

    boolean matchesStoredJson(JSONObject value) {
        if (value == null || request == null || !hasOnlyCanonicalKeys(value)
                || !exactString(value, "pseudonym", pseudonym)
                || !exactString(value, "platform", "threads")
                || !exactString(value, "targetId", request.getProfileId())
                || !exactString(value, "targetUser", request.getProfileUsername())
                || !exactString(value, "targetName", request.getDisplayName())
                || !exactString(value, "targetUrl", request.getPermalink())
                || !exactString(value, "reason", reason)
                || !exactString(value, "note", note)
                || !exactString(value, "quote", request.getPostContent())) {
            return false;
        }
        Object rawEvidence = value.opt("evidence");
        if (!(rawEvidence instanceof JSONArray)) {
            return false;
        }
        JSONArray evidence = (JSONArray) rawEvidence;
        String permalink = request.getPermalink();
        if (permalink.length() == 0) {
            if (evidence.length() != 0) {
                return false;
            }
        } else if (evidence.length() != 1
                || !(evidence.opt(0) instanceof String)
                || !permalink.equals(evidence.optString(0, ""))) {
            return false;
        }
        return optionalExactString(value, "tz", timeZone)
                && optionalExactString(value, "lang", language);
    }

    String targetKey() {
        return request == null ? "" : request.targetKey();
    }

    JSONObject toJson() {
        JSONObject value = new JSONObject();
        if (!isValid()) {
            return value;
        }
        try {
            value.put("pseudonym", pseudonym);
            value.put("platform", "threads");
            value.put("targetId", request.getProfileId());
            value.put("targetUser", request.getProfileUsername());
            value.put("targetName", request.getDisplayName());
            value.put("targetUrl", request.getPermalink());
            value.put("reason", reason);
            value.put("note", note);
            value.put("quote", request.getPostContent());
            JSONArray evidence = new JSONArray();
            if (request.getPermalink().length() > 0) {
                evidence.put(request.getPermalink());
            }
            value.put("evidence", evidence);
            if (timeZone.length() > 0) {
                value.put("tz", timeZone);
            }
            if (language.length() > 0) {
                value.put("lang", language);
            }
        } catch (Throwable ignored) {
            return new JSONObject();
        }
        return value;
    }

    static ReportPayload fromJson(JSONObject value) {
        if (value == null || !"threads".equals(value.optString("platform", ""))) {
            return null;
        }
        ReportRequest request = new ReportRequest(
                value.optString("targetUser", ""),
                value.optString("targetId", ""),
                value.optString("quote", ""),
                value.optString("targetName", ""),
                value.optString("targetUrl", ""));
        ReportPayload payload = new ReportPayload(
                value.optString("pseudonym", ""),
                request,
                value.optString("reason", ""),
                value.optString("note", ""),
                value.optString("lang", ""),
                value.optString("tz", ""));
        return payload.isValid() ? payload : null;
    }

    public static boolean isReason(String value) {
        return REASON_REDBULL.equals(value) || REASON_CLONE.equals(value)
                || REASON_IMPERSONATION.equals(value) || REASON_SCAM.equals(value)
                || REASON_HARASSMENT.equals(value) || REASON_SPAM.equals(value)
                || REASON_OTHER.equals(value);
    }

    private static boolean exactString(JSONObject value, String key, String expected) {
        Object raw = value.opt(key);
        return raw instanceof String && expected.equals(raw);
    }

    private static boolean optionalExactString(
            JSONObject value, String key, String expected) {
        if (expected.length() == 0) {
            return !value.has(key);
        }
        return exactString(value, key, expected);
    }

    private boolean hasOnlyCanonicalKeys(JSONObject value) {
        Set<String> allowed = new HashSet<String>();
        allowed.add("pseudonym");
        allowed.add("platform");
        allowed.add("targetId");
        allowed.add("targetUser");
        allowed.add("targetName");
        allowed.add("targetUrl");
        allowed.add("reason");
        allowed.add("note");
        allowed.add("quote");
        allowed.add("evidence");
        if (timeZone.length() > 0) {
            allowed.add("tz");
        }
        if (language.length() > 0) {
            allowed.add("lang");
        }
        Iterator<String> keys = value.keys();
        int count = 0;
        while (keys.hasNext()) {
            if (!allowed.contains(keys.next())) {
                return false;
            }
            count++;
        }
        return count == allowed.size();
    }
}
