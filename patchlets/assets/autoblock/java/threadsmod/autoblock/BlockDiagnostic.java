package threadsmod.autoblock;

/**
 * Closed, identifier-free diagnostic formatting for local Block failures.
 *
 * The only variable input is a bridge or scheduler stage token. Unknown input
 * is never copied into an output. Context is expressed only by booleans, so a
 * diagnostic cannot receive account IDs, host objects, network locations, or
 * exception text.
 */
public final class BlockDiagnostic {
    public static final int MAX_DETAIL_CHARS = 120;
    public static final int MAX_STATUS_CHARS = 240;
    public static final int MAX_LOG_CHARS = 200;

    private final String stage;
    private final String code;
    private final String detail;
    private final String status;
    private final String logLine;

    private BlockDiagnostic(
            String stage,
            String code,
            String detail,
            String status,
            String logLine) {
        this.stage = stage;
        this.code = code;
        this.detail = bounded(detail, MAX_DETAIL_CHARS);
        this.status = bounded(status, MAX_STATUS_CHARS);
        this.logLine = bounded(logLine, MAX_LOG_CHARS);
    }

    /**
     * Builds one safe diagnostic without accepting any operation identity or
     * dynamic host/network error object.
     */
    public static BlockDiagnostic forFailure(
            String inputStage,
            boolean automatic,
            boolean resolvedRowModel,
            boolean nativeStarted,
            boolean recoveryStateSaved) {
        String stage = "unknown_failure";
        String code = "CB-UNK-000";
        String summary = "unknown failure";
        String explanation = "Block stopped for an unknown local reason.";
        String route = resolvedRowModel ? "row-model" : "direct-id";
        String mutation = nativeStarted ? "started" : "unknown";
        boolean reviewRequired = false;

        if ("bridge_exception".equals(inputStage)) {
            stage = "bridge_exception";
            code = "CB-BRG-103";
            summary = "native bridge stopped";
            explanation = "The same-version native Block bridge stopped unexpectedly; success was not confirmed.";
            mutation = nativeStarted ? "started" : "unknown";
        } else if ("session_model_exception".equals(inputStage)) {
            stage = "session_model_exception";
            code = "CB-BRG-107";
            summary = "session model rejected";
            explanation = "The same-version Threads session could not enter the native Block bridge, so no mutation was sent.";
            route = "session";
            mutation = "no";
        } else if ("cache_lookup_exception".equals(inputStage)) {
            stage = "cache_lookup_exception";
            code = "CB-BRG-108";
            summary = "user cache lookup stopped";
            explanation = "The reviewed same-version user-cache lookup stopped before Block submission.";
            route = "cache-first";
            mutation = "no";
        } else if ("cache_factory_exception".equals(inputStage)) {
            stage = "cache_factory_exception";
            code = "CB-BRG-109";
            summary = "user cache unavailable";
            explanation = "Threads did not provide its same-session user cache, so no Block mutation was sent.";
            route = "cache-factory";
            mutation = "no";
        } else if ("cache_placeholder_exception".equals(inputStage)) {
            stage = "cache_placeholder_exception";
            code = "CB-BRG-110";
            summary = "direct-ID model construction stopped";
            explanation = "Threads could not construct its same-version model for the numeric target, so no mutation was sent.";
            route = "cache-placeholder";
            mutation = "no";
        } else if ("bridge_dispatch_exception".equals(inputStage)) {
            stage = "bridge_dispatch_exception";
            code = "CB-BRG-111";
            summary = "native bridge preparation stopped";
            explanation = "The reviewed native model preparation stopped before Block submission.";
            mutation = "no";
        } else if ("model_id_exception".equals(inputStage)) {
            stage = "model_id_exception";
            code = "CB-BRG-112";
            summary = "model identity read stopped";
            explanation = "Threads could not read the reviewed model identity, so no Block mutation was sent.";
            mutation = "no";
        } else if ("already_blocked_exception".equals(inputStage)) {
            stage = "already_blocked_exception";
            code = "CB-BRG-113";
            summary = "Block state read stopped";
            explanation = "Threads could not read the reviewed Block state, so no Block mutation was sent.";
            mutation = "no";
        } else if ("resolved_model_invalid".equals(inputStage)) {
            stage = "resolved_model_invalid";
            code = "CB-BRG-104";
            summary = "row model rejected";
            explanation = "The displayed row model could not be accepted safely, so no Block mutation was sent.";
            route = "row-model";
            mutation = "no";
        } else if ("model_id_mismatch".equals(inputStage)) {
            stage = "model_id_mismatch";
            code = "CB-BRG-105";
            summary = "model identity mismatch";
            explanation = "The native model identity did not match the requested target, so no Block mutation was sent.";
            mutation = "no";
        } else if ("placeholder_model_invalid".equals(inputStage)) {
            stage = "placeholder_model_invalid";
            code = "CB-BRG-106";
            summary = "direct-ID model rejected";
            explanation = "Threads could not create a safe same-version model for the numeric target, so no Block mutation was sent.";
            route = "direct-id";
            mutation = "no";
        } else if ("mutation_failure".equals(inputStage)) {
            stage = "mutation_failure";
            code = "CB-MUT-201";
            summary = "native mutation failed";
            explanation = "Threads reported that the Block mutation failed; success was not confirmed.";
            mutation = nativeStarted ? "started" : "unknown";
        } else if ("mutation_ended".equals(inputStage)) {
            stage = "mutation_ended";
            code = "CB-MUT-202";
            summary = "native mutation ended";
            explanation = "The native mutation ended without a success callback; Block success was not recorded.";
            mutation = nativeStarted ? "started" : "unknown";
        } else if ("mutation_cancelled".equals(inputStage)) {
            stage = "mutation_cancelled";
            code = "CB-MUT-203";
            summary = "native mutation cancelled";
            explanation = "The native mutation was cancelled without confirmed Block success.";
            mutation = nativeStarted ? "started" : "unknown";
        } else if ("mutation_exception".equals(inputStage)) {
            stage = "mutation_exception";
            code = "CB-MUT-204";
            summary = "mutation bridge stopped";
            explanation = "The native mutation bridge stopped unexpectedly; Block success was not confirmed.";
            mutation = nativeStarted ? "started" : "unknown";
        } else if ("callback_timeout".equals(inputStage)) {
            stage = "callback_timeout";
            code = "CB-MUT-205";
            summary = "native callback timed out";
            explanation = "Threads did not return a terminal Block callback in time; the account state needs review.";
            mutation = nativeStarted ? "started" : "unknown";
            reviewRequired = true;
        } else if ("completion_persistence".equals(inputStage)) {
            stage = "completion_persistence";
            code = "CB-LOC-301";
            summary = "local completion save failed";
            explanation = nativeStarted
                    ? "Threads confirmed Block success, but the local completion record could not be saved. Review Activity before retrying."
                    : "Threads confirmed the target is already blocked, but the local completion record could not be saved. Review Activity before retrying.";
            mutation = nativeStarted ? "success" : "no";
            reviewRequired = true;
        } else if ("queue_start_persistence".equals(inputStage)) {
            stage = "queue_start_persistence";
            code = "CB-LOC-101";
            summary = "queue start save failed";
            explanation = "The queued action could not be durably marked started, so no Block mutation was sent.";
            route = "scheduler";
            mutation = "no";
        } else if ("attempt_reservation".equals(inputStage)) {
            stage = "attempt_reservation";
            code = "CB-LOC-102";
            summary = "attempt reservation failed";
            explanation = "The local rate-limit attempt could not be durably reserved, so no Block mutation was sent.";
            route = "scheduler";
            mutation = "no";
        } else if ("foreground_changed".equals(inputStage)) {
            stage = "foreground_changed";
            code = "CB-SCH-101";
            summary = "foreground context changed";
            explanation = "The active Threads screen changed before Block could continue safely.";
            route = "scheduler";
            mutation = "no";
        } else if ("scheduler_handoff".equals(inputStage)) {
            stage = "scheduler_handoff";
            code = "CB-SCH-102";
            summary = "scheduler ownership changed";
            explanation = "The single-flight scheduler changed owners before Block submission.";
            route = "scheduler";
            mutation = "no";
        } else if ("invalid_or_self_target".equals(inputStage)
                || "invalid_target".equals(inputStage)
                || "self_block_refused".equals(inputStage)) {
            stage = "invalid_target";
            code = "CB-SCH-103";
            summary = "target refused";
            explanation = "The target was missing, invalid, or the active viewer; no Block mutation was sent.";
            route = "validation";
            mutation = "no";
        } else if ("viewer_changed".equals(inputStage)) {
            stage = "viewer_changed";
            code = "CB-SCH-104";
            summary = "viewer context changed";
            explanation = "The active Threads viewer changed before Block could continue safely.";
            route = "validation";
            mutation = "no";
        } else if ("already_completed".equals(inputStage)) {
            stage = "already_completed";
            code = "CB-SCH-107";
            summary = "target already completed";
            explanation = "Clone Blocker already recorded this profile as blocked for the active account, so no new Block was queued.";
            route = "validation";
            mutation = "no";
        } else if ("queue_rejected".equals(inputStage)
                || "scheduler_rejected".equals(inputStage)) {
            stage = "scheduler_rejected";
            code = "CB-SCH-105";
            summary = "scheduler rejected action";
            explanation = "The safe local scheduler did not accept this Block action.";
            route = "scheduler";
            mutation = "no";
        } else if ("no_foreground_session".equals(inputStage)
                || "foreground_lost".equals(inputStage)) {
            stage = "no_foreground_session";
            code = "CB-SCH-106";
            summary = "foreground session unavailable";
            explanation = "No matching signed-in foreground Threads session was available for Block.";
            route = "validation";
            mutation = "no";
        } else if ("confirmation_unavailable".equals(inputStage)) {
            stage = "confirmation_unavailable";
            code = "CB-UI-101";
            summary = "confirmation unavailable";
            explanation = "The local Block confirmation could not be shown; no action was queued.";
            route = "confirmation";
            mutation = "no";
        } else if ("report_context_unavailable".equals(inputStage)) {
            stage = "report_context_unavailable";
            code = "CB-UI-102";
            summary = "combined action unavailable";
            explanation = "The combined action lost its foreground context; neither Report nor Block was submitted.";
            route = "confirmation";
            mutation = "no";
        } else if ("bridge_stub".equals(inputStage)) {
            stage = "bridge_stub";
            code = "CB-BRG-999";
            summary = "release bridge missing";
            explanation = "The compile-time bridge stub was reached; this build must not perform account actions.";
            mutation = "no";
        }

        String source = automatic ? "automatic" : "inline";
        String detail = code
                + " · source=" + source
                + " · route=" + route
                + " · mutation=" + mutation
                + " · mirror=n/a"
                + " · bridge=r6"
                + " · " + summary;
        String retry = reviewRequired
                ? recoveryStateSaved
                        ? "review-saved" : "review-local-failclosed"
                : recoveryStateSaved ? "backoff" : "local-state-failed";
        String status = code
                + " [stage=" + stage
                + "; source=" + source
                + "; route=" + route
                + "; mutation=" + mutation
                + "; retry=" + retry
                + "; mirror=n/a; bridge=r6] "
                + explanation
                + (reviewRequired
                        ? recoveryStateSaved
                                ? " The target was durably quarantined; automatic retry is disabled."
                                : " A process-local quarantine is active; automatic work is paused."
                        : recoveryStateSaved
                                ? " A local two-minute retry pause was saved."
                                : " The retry pause could not be saved; processing remains fail-closed.");
        String logLine = detail + " · stage=" + stage + " · retry=" + retry;
        return new BlockDiagnostic(stage, code, detail, status, logLine);
    }

    public String stage() {
        return stage;
    }

    public String code() {
        return code;
    }

    public String detail() {
        return detail;
    }

    public String status() {
        return status;
    }

    public String logLine() {
        return logLine;
    }

    private static String bounded(String value, int maximum) {
        if (value == null) {
            return "";
        }
        return value.length() <= maximum ? value : value.substring(0, maximum);
    }
}
