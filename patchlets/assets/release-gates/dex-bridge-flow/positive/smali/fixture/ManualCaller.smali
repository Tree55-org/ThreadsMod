.class public final Lfixture/ManualCaller;
.super Ljava/lang/Object;
.source "ManualCaller.java"

.implements Lthreadsmod/autoblock/BridgeCallback;


# instance fields
.field private final activity:Landroid/app/Activity;

.field private final finished:Ljava/util/concurrent/atomic/AtomicBoolean;

.field private final resolvedAuthorModel:Ljava/lang/Object;

.field private final schedulerToken:J

.field private started:Z

.field private final targetId:Ljava/lang/String;

.field private final userSession:Ljava/lang/Object;

.field private final viewer:Ljava/lang/String;


# direct methods
.method static synthetic access$abandon(Lfixture/ManualCaller;)V
    .locals 0

    invoke-direct {p0}, Lfixture/ManualCaller;->abandonUncertainMutation()V

    return-void
.end method

.method private abandonUncertainMutation()V
    .locals 10

    iget-object v0, p0, Lfixture/ManualCaller;->finished:Ljava/util/concurrent/atomic/AtomicBoolean;

    const/4 v1, 0x0

    const/4 v2, 0x1

    invoke-virtual {v0, v1, v2}, Ljava/util/concurrent/atomic/AtomicBoolean;->compareAndSet(ZZ)Z

    move-result v0

    if-nez v0, :terminal_latched

    return-void

    :terminal_latched
    iget-wide v3, p0, Lfixture/ManualCaller;->schedulerToken:J

    invoke-static {v3, v4, v1}, Lthreadsmod/autoblock/AutoBlockSync;->markSchedulerMutationInFlight(JZ)Z

    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v3, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v4, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-static {v0, v3, v4}, Lthreadsmod/autoblock/AutoBlockSync;->quarantineCompletionReview(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z

    move-result v0

    iget-object v3, p0, Lfixture/ManualCaller;->resolvedAuthorModel:Ljava/lang/Object;

    if-eqz v3, :no_resolved_model

    goto :resolved_model_presence_ready

    :no_resolved_model
    move v2, v1

    :resolved_model_presence_ready
    iget-boolean v3, p0, Lfixture/ManualCaller;->started:Z

    const-string v4, "callback_timeout"

    invoke-static {v4, v1, v2, v3, v0}, Lthreadsmod/autoblock/BlockDiagnostic;->forFailure(Ljava/lang/String;ZZZZ)Lthreadsmod/autoblock/BlockDiagnostic;

    move-result-object v1

    :try_manual_queue_record_start
    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v3, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-virtual {v1}, Lthreadsmod/autoblock/BlockDiagnostic;->detail()Ljava/lang/String;

    move-result-object v4

    invoke-static {v0, v2, v3, v4}, Lthreadsmod/autoblock/ModStateStore;->markManualAbandoned(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z
    :try_manual_queue_record_end
    .catchall {:try_manual_queue_record_start .. :try_manual_queue_record_end} :catch_manual_queue_record

    goto :manual_queue_record_done

    :catch_manual_queue_record
    move-exception v0

    :manual_queue_record_done
    :try_manual_diagnostic_status_start

    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    invoke-static {v0, v2, v1}, Lthreadsmod/autoblock/ModStateStore;->recordFailureDiagnostic(Landroid/content/Context;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)V

    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    invoke-virtual {v1}, Lthreadsmod/autoblock/BlockDiagnostic;->status()Ljava/lang/String;

    move-result-object v3

    invoke-static {v0, v2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V
    :try_manual_diagnostic_status_end
    .catchall {:try_manual_diagnostic_status_start .. :try_manual_diagnostic_status_end} :catch_manual_diagnostic_status

    goto :manual_diagnostic_status_done

    :catch_manual_diagnostic_status
    move-exception v0

    :manual_diagnostic_status_done
    :try_manual_log_start
    const-string v0, "ThreadsModAutoBlock"

    invoke-virtual {v1}, Lthreadsmod/autoblock/BlockDiagnostic;->logLine()Ljava/lang/String;

    move-result-object v2

    invoke-static {v0, v2}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I
    :try_manual_log_end
    .catchall {:try_manual_log_start .. :try_manual_log_end} :catch_manual_log

    goto :manual_log_done

    :catch_manual_log
    move-exception v0

    :manual_log_done

    :try_scheduler_release_start
    iget-wide v3, p0, Lfixture/ManualCaller;->schedulerToken:J

    iget-object v5, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v6, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    const-wide/16 v7, 0x0

    const/4 v9, 0x0

    invoke-static/range {v3 .. v9}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V
    :try_scheduler_release_end
    .catchall {:try_scheduler_release_start .. :try_scheduler_release_end} :catch_scheduler_release

    iget-object v0, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v2, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-virtual {v1}, Lthreadsmod/autoblock/BlockDiagnostic;->stage()Ljava/lang/String;

    move-result-object v1

    invoke-static {v0, v2, v1}, Lthreadsmod/autoblock/AutoBlockSync;->dispatchManualFailure(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V

    return-void

    :catch_scheduler_release
    move-exception v0

    iget-object v2, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v3, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-virtual {v1}, Lthreadsmod/autoblock/BlockDiagnostic;->stage()Ljava/lang/String;

    move-result-object v1

    invoke-static {v2, v3, v1}, Lthreadsmod/autoblock/AutoBlockSync;->dispatchManualFailure(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V

    throw v0
.end method

.method private constructor <init>()V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method private fail(Ljava/lang/String;)V
    .locals 9

    const-string v0, "callback_timeout"

    invoke-virtual {v0, p1}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :manual_failure_regular

    invoke-direct {p0}, Lfixture/ManualCaller;->abandonUncertainMutation()V

    return-void

    :manual_failure_regular
    iget-object v0, p0, Lfixture/ManualCaller;->finished:Ljava/util/concurrent/atomic/AtomicBoolean;

    const/4 v1, 0x0

    const/4 v2, 0x1

    invoke-virtual {v0, v1, v2}, Ljava/util/concurrent/atomic/AtomicBoolean;->compareAndSet(ZZ)Z

    move-result v0

    if-nez v0, :manual_failure_latched

    return-void

    :manual_failure_latched
    iget-wide v3, p0, Lfixture/ManualCaller;->schedulerToken:J

    invoke-static {v3, v4, v1}, Lthreadsmod/autoblock/AutoBlockSync;->markSchedulerMutationInFlight(JZ)Z

    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v3, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    invoke-static {v0, v3}, Lthreadsmod/autoblock/AutoBlockSync;->persistRetryDeadline(Landroid/content/Context;Ljava/lang/String;)Z

    move-result v0

    iget-object v3, p0, Lfixture/ManualCaller;->resolvedAuthorModel:Ljava/lang/Object;

    if-eqz v3, :manual_failure_no_model

    goto :manual_failure_model_ready

    :manual_failure_no_model
    move v2, v1

    :manual_failure_model_ready
    iget-boolean v3, p0, Lfixture/ManualCaller;->started:Z

    invoke-static {p1, v1, v2, v3, v0}, Lthreadsmod/autoblock/BlockDiagnostic;->forFailure(Ljava/lang/String;ZZZZ)Lthreadsmod/autoblock/BlockDiagnostic;

    move-result-object p1

    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v2, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-static {v0, v1, v2, p1}, Lthreadsmod/autoblock/ModStateStore;->markManualFailed(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)Z

    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    invoke-static {v0, v1, p1}, Lthreadsmod/autoblock/ModStateStore;->recordFailureDiagnostic(Landroid/content/Context;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)V

    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    invoke-virtual {p1}, Lthreadsmod/autoblock/BlockDiagnostic;->status()Ljava/lang/String;

    move-result-object v2

    invoke-static {v0, v1, v2}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    const-string v0, "ThreadsModAutoBlock"

    invoke-virtual {p1}, Lthreadsmod/autoblock/BlockDiagnostic;->logLine()Ljava/lang/String;

    move-result-object v1

    invoke-static {v0, v1}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    iget-wide v2, p0, Lfixture/ManualCaller;->schedulerToken:J

    iget-object v4, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v5, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    const-wide/32 v6, 0x1d8a8

    const/4 v8, 0x1

    invoke-static/range {v2 .. v8}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V

    iget-object v0, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v1, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-virtual {p1}, Lthreadsmod/autoblock/BlockDiagnostic;->stage()Ljava/lang/String;

    move-result-object p1

    invoke-static {v0, v1, p1}, Lthreadsmod/autoblock/AutoBlockSync;->dispatchManualFailure(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V

    return-void
.end method

.method private handleCompletionPersistenceAfterSuccess()V
    .locals 10

    iget-wide v0, p0, Lfixture/ManualCaller;->schedulerToken:J

    const/4 v2, 0x0

    invoke-static {v0, v1, v2}, Lthreadsmod/autoblock/AutoBlockSync;->markSchedulerMutationInFlight(JZ)Z

    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v3, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-static {v0, v1, v3}, Lthreadsmod/autoblock/AutoBlockSync;->quarantineCompletionReview(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z

    move-result v0

    iget-object v1, p0, Lfixture/ManualCaller;->resolvedAuthorModel:Ljava/lang/Object;

    const/4 v3, 0x1

    if-eqz v1, :completion_no_model

    move v1, v3

    goto :completion_model_ready

    :completion_no_model
    move v1, v2

    :completion_model_ready
    const-string v4, "completion_persistence"

    invoke-static {v4, v2, v1, v3, v0}, Lthreadsmod/autoblock/BlockDiagnostic;->forFailure(Ljava/lang/String;ZZZZ)Lthreadsmod/autoblock/BlockDiagnostic;

    move-result-object v1

    :try_manual_completion_queue_start
    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v3, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-static {v0, v2, v3, v1}, Lthreadsmod/autoblock/ModStateStore;->markManualFailed(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)Z
    :try_manual_completion_queue_end
    .catchall {:try_manual_completion_queue_start .. :try_manual_completion_queue_end} :catch_manual_completion_queue

    goto :manual_completion_queue_done

    :catch_manual_completion_queue
    move-exception v0

    :manual_completion_queue_done
    :try_manual_completion_diagnostic_start
    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    invoke-static {v0, v2, v1}, Lthreadsmod/autoblock/ModStateStore;->recordFailureDiagnostic(Landroid/content/Context;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)V

    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    invoke-virtual {v1}, Lthreadsmod/autoblock/BlockDiagnostic;->status()Ljava/lang/String;

    move-result-object v3

    invoke-static {v0, v2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V
    :try_manual_completion_diagnostic_end
    .catchall {:try_manual_completion_diagnostic_start .. :try_manual_completion_diagnostic_end} :catch_manual_completion_diagnostic

    goto :manual_completion_diagnostic_done

    :catch_manual_completion_diagnostic
    move-exception v0

    :manual_completion_diagnostic_done
    :try_manual_completion_log_start
    const-string v0, "ThreadsModAutoBlock"

    invoke-virtual {v1}, Lthreadsmod/autoblock/BlockDiagnostic;->logLine()Ljava/lang/String;

    move-result-object v2

    invoke-static {v0, v2}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I
    :try_manual_completion_log_end
    .catchall {:try_manual_completion_log_start .. :try_manual_completion_log_end} :catch_manual_completion_log

    goto :manual_completion_log_done

    :catch_manual_completion_log
    move-exception v0

    :manual_completion_log_done
    :try_manual_completion_release_start
    iget-wide v3, p0, Lfixture/ManualCaller;->schedulerToken:J

    iget-object v5, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v6, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    const-wide/16 v7, 0x0

    const/4 v9, 0x0

    invoke-static/range {v3 .. v9}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V
    :try_manual_completion_release_end
    .catchall {:try_manual_completion_release_start .. :try_manual_completion_release_end} :catch_manual_completion_release

    iget-object v0, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v2, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-virtual {v1}, Lthreadsmod/autoblock/BlockDiagnostic;->stage()Ljava/lang/String;

    move-result-object v1

    invoke-static {v0, v2, v1}, Lthreadsmod/autoblock/AutoBlockSync;->dispatchManualFailure(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V

    nop

    nop

    return-void

    :catch_manual_completion_release
    move-exception v0

    iget-object v2, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v3, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-virtual {v1}, Lthreadsmod/autoblock/BlockDiagnostic;->stage()Ljava/lang/String;

    move-result-object v1

    invoke-static {v2, v3, v1}, Lthreadsmod/autoblock/AutoBlockSync;->dispatchManualFailure(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V

    throw v0
.end method

.method private isCurrent(Ljava/lang/String;)Z
    .locals 2

    iget-object v0, p0, Lfixture/ManualCaller;->finished:Ljava/util/concurrent/atomic/AtomicBoolean;

    invoke-virtual {v0}, Ljava/util/concurrent/atomic/AtomicBoolean;->get()Z

    move-result v0

    if-nez v0, :not_current

    iget-wide v0, p0, Lfixture/ManualCaller;->schedulerToken:J

    invoke-static {v0, v1}, Lthreadsmod/autoblock/AutoBlockSync;->isSchedulerOwner(J)Z

    move-result v0

    if-eqz v0, :not_current

    iget-object v0, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-virtual {v0, p1}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :not_current

    const/4 v0, 0x1

    goto :current_join

    :not_current
    const/4 v0, 0x0

    :current_join
    return v0
.end method

.method private isCurrentForeground()Z
    .locals 2

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->getForegroundActivity()Landroid/app/Activity;

    move-result-object v0

    iget-object v1, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    if-ne v0, v1, :foreground_false

    iget-object v0, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->getCurrentViewer()Ljava/lang/String;

    move-result-object v1

    invoke-virtual {v0, v1}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :foreground_false

    iget-object v0, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v1, p0, Lfixture/ManualCaller;->userSession:Ljava/lang/Object;

    invoke-static {v1}, Lthreadsmod/autoblock/AutoBlockSync;->access$viewerId(Ljava/lang/Object;)Ljava/lang/String;

    move-result-object v1

    invoke-virtual {v0, v1}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :foreground_false

    const/4 v0, 0x1

    goto :foreground_join

    :foreground_false
    const/4 v0, 0x0

    :foreground_join
    return v0
.end method


# virtual methods
.method public begin()V
    .locals 5

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->isMainLooperThread()Z

    move-result v0

    if-nez v0, :manual_main_thread

    const-string v0, "scheduler_handoff"

    invoke-direct {p0, v0}, Lfixture/ManualCaller;->fail(Ljava/lang/String;)V

    return-void

    :manual_main_thread
    invoke-direct {p0}, Lfixture/ManualCaller;->isCurrentForeground()Z

    move-result v0

    if-nez v0, :manual_foreground_current

    const-string v0, "foreground_changed"

    invoke-direct {p0, v0}, Lfixture/ManualCaller;->fail(Ljava/lang/String;)V

    return-void

    :manual_foreground_current
    iget-wide v0, p0, Lfixture/ManualCaller;->schedulerToken:J

    const/4 v2, 0x1

    invoke-static {v0, v1, v2}, Lthreadsmod/autoblock/AutoBlockSync;->markSchedulerMutationInFlight(JZ)Z

    move-result v0

    if-nez v0, :try_bridge_start

    const-string v0, "scheduler_handoff"

    invoke-direct {p0, v0}, Lfixture/ManualCaller;->fail(Ljava/lang/String;)V

    return-void

    :try_bridge_start
    iget-object v0, p0, Lfixture/ManualCaller;->resolvedAuthorModel:Ljava/lang/Object;

    if-nez v0, :resolved

    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/ManualCaller;->userSession:Ljava/lang/Object;

    iget-object v2, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-static {v0, v1, v2, p0}, Lthreadsmod/autoblock/ThreadsBlockBridge;->block(Landroid/app/Activity;Ljava/lang/Object;Ljava/lang/String;Lthreadsmod/autoblock/BridgeCallback;)V

    goto :bridge_done

    :resolved
    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/ManualCaller;->userSession:Ljava/lang/Object;

    iget-object v3, p0, Lfixture/ManualCaller;->resolvedAuthorModel:Ljava/lang/Object;

    iget-object v2, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-static {v0, v1, v3, v2, p0}, Lthreadsmod/autoblock/ThreadsBlockBridge;->blockResolved(Landroid/app/Activity;Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/String;Lthreadsmod/autoblock/BridgeCallback;)V
    :try_bridge_end
    .catchall {:try_bridge_start .. :try_bridge_end} :catch_bridge

    :bridge_done
    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->access$main()Landroid/os/Handler;

    move-result-object v0

    new-instance v1, Lfixture/ManualCaller$WatchdogRunnable;

    invoke-direct {v1, p0}, Lfixture/ManualCaller$WatchdogRunnable;-><init>(Lfixture/ManualCaller;)V

    const-wide/32 v2, 0xafc8

    invoke-virtual {v0, v1, v2, v3}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    move-result v0

    if-nez v0, :watchdog_accepted

    invoke-direct {p0}, Lfixture/ManualCaller;->abandonUncertainMutation()V

    :watchdog_accepted
    return-void

    :catch_bridge
    move-exception v0

    const-string v0, "bridge_exception"

    invoke-direct {p0, v0}, Lfixture/ManualCaller;->fail(Ljava/lang/String;)V

    return-void
.end method

.method public onBridgeFailure(Ljava/lang/String;Ljava/lang/String;)V
    .locals 1

    iget-object v0, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-virtual {v0, p1}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :done

    invoke-direct {p0, p2}, Lfixture/ManualCaller;->fail(Ljava/lang/String;)V

    :done
    return-void
.end method

.method public onBridgeStarted(Ljava/lang/String;)V
    .locals 5

    invoke-direct {p0, p1}, Lfixture/ManualCaller;->isCurrent(Ljava/lang/String;)Z

    move-result v0

    if-eqz v0, :done

    iget-boolean v0, p0, Lfixture/ManualCaller;->started:Z

    if-eqz v0, :fresh_start

    goto :done

    :fresh_start

    const/4 v0, 0x1

    iput-boolean v0, p0, Lfixture/ManualCaller;->started:Z

    iget-object v1, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v2, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-static {v1, v2}, Lthreadsmod/autoblock/AutoBlockSync;->dispatchManualStarted(Ljava/lang/String;Ljava/lang/String;)V

    iget-object v0, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    const-string v3, "Blocking the selected profile..."

    invoke-static {v0, v1, v3}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    const-string v2, "manual_in_flight"

    const-string v3, "An inline block is in flight."

    const/4 v4, 0x0

    invoke-static {v0, v1, v2, v3, v4}, Lthreadsmod/autoblock/ModStateStore;->recordRuntimeState(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Z)V

    :done
    return-void
.end method

.method public onBridgeSuccess(Ljava/lang/String;)V
    .locals 9

    invoke-direct {p0, p1}, Lfixture/ManualCaller;->isCurrent(Ljava/lang/String;)Z

    move-result v0

    if-eqz v0, :done

    iget-object v0, p0, Lfixture/ManualCaller;->finished:Ljava/util/concurrent/atomic/AtomicBoolean;

    const/4 v1, 0x0

    const/4 v2, 0x1

    invoke-virtual {v0, v1, v2}, Ljava/util/concurrent/atomic/AtomicBoolean;->compareAndSet(ZZ)Z

    move-result v0

    if-nez v0, :terminal_latched

    return-void

    :terminal_latched

    const/4 v7, 0x0

    :try_completion_save_start
    iget-object v2, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v3, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v4, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-static {v2, v3, v4}, Lthreadsmod/autoblock/ModStateStore;->markManualBlocked(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z

    move-result v0
    :try_completion_save_end
    .catchall {:try_completion_save_start .. :try_completion_save_end} :catch_completion_save

    goto :completion_save_join

    :catch_completion_save
    move-exception v1

    move v0, v7

    :completion_save_join
    if-nez v0, :completion_saved

    invoke-direct {p0}, Lfixture/ManualCaller;->handleCompletionPersistenceAfterSuccess()V

    return-void

    :completion_saved
    iget-wide v0, p0, Lfixture/ManualCaller;->schedulerToken:J

    const/4 v2, 0x0

    invoke-static {v0, v1, v2}, Lthreadsmod/autoblock/AutoBlockSync;->markSchedulerMutationInFlight(JZ)Z

    :try_manual_success_clear_retry_start
    iget-object v2, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v3, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    invoke-static {v2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->clearRetryDeadline(Landroid/content/Context;Ljava/lang/String;)Z
    :try_manual_success_clear_retry_end
    .catchall {:try_manual_success_clear_retry_start .. :try_manual_success_clear_retry_end} :catch_manual_success_clear_retry

    goto :manual_success_clear_retry_done

    :catch_manual_success_clear_retry
    move-exception v2

    :manual_success_clear_retry_done
    :try_manual_success_state_start
    iget-object v2, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v3, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    const-string v4, "Inline Block completed after Threads confirmed success."

    invoke-static {v2, v3, v4}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    iget-object v2, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v3, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    const-string v4, "manual_succeeded"

    const-string v5, "Threads confirmed the inline block."

    invoke-static {v2, v3, v4, v5, v7}, Lthreadsmod/autoblock/ModStateStore;->recordRuntimeState(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Z)V
    :try_manual_success_state_end
    .catchall {:try_manual_success_state_start .. :try_manual_success_state_end} :catch_manual_success_state

    goto :manual_success_state_done

    :catch_manual_success_state
    move-exception v2

    :manual_success_state_done
    :try_dispatch_start
    iget-object v2, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    iget-object v3, p0, Lfixture/ManualCaller;->targetId:Ljava/lang/String;

    invoke-static {v2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->dispatchManualSuccess(Ljava/lang/String;Ljava/lang/String;)V
    :try_dispatch_end
    .catchall {:try_dispatch_start .. :try_dispatch_end} :catch_dispatch

    :try_normal_pace_start
    iget-object v2, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    invoke-static {v2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->millisUntilPaceAllowed(Landroid/content/Context;Ljava/lang/String;)J

    move-result-wide v4
    :try_normal_pace_end
    .catchall {:try_normal_pace_start .. :try_normal_pace_end} :catch_normal_pace

    goto :normal_pace_join

    :catch_normal_pace
    move-exception v2

    const-wide/16 v4, 0x0

    :normal_pace_join
    iget-wide v0, p0, Lfixture/ManualCaller;->schedulerToken:J

    iget-object v2, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v3, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    const/4 v6, 0x1

    invoke-static/range {v0 .. v6}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V

    goto :done

    :catch_dispatch
    move-exception v7

    move-object v8, v7

    :try_exceptional_pace_start
    iget-object v2, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v3, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    invoke-static {v2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->millisUntilPaceAllowed(Landroid/content/Context;Ljava/lang/String;)J

    move-result-wide v4
    :try_exceptional_pace_end
    .catchall {:try_exceptional_pace_start .. :try_exceptional_pace_end} :catch_exceptional_pace

    goto :exceptional_pace_join

    :catch_exceptional_pace
    move-exception v2

    const-wide/16 v4, 0x0

    :exceptional_pace_join
    iget-wide v0, p0, Lfixture/ManualCaller;->schedulerToken:J

    iget-object v2, p0, Lfixture/ManualCaller;->activity:Landroid/app/Activity;

    iget-object v3, p0, Lfixture/ManualCaller;->viewer:Ljava/lang/String;

    const/4 v6, 0x1

    invoke-static/range {v0 .. v6}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V

    throw v8

    :done
    return-void
.end method
