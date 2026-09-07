.class public final Lfixture/AutomaticCaller;
.super Ljava/lang/Object;
.source "AutomaticCaller.java"

.implements Lthreadsmod/autoblock/BridgeCallback;


# instance fields
.field private final activity:Landroid/app/Activity;

.field private attemptsThisRun:I

.field private currentId:Ljava/lang/String;

.field private final finished:Ljava/util/concurrent/atomic/AtomicBoolean;

.field private final forceRefresh:Z

.field private index:I

.field private final schedulerToken:J

.field private started:Z

.field private successesThisRun:I

.field private final targetId:Ljava/lang/String;

.field private final targets:Ljava/util/List;

.field private final userSession:Ljava/lang/Object;

.field private final viewer:Ljava/lang/String;

.field private token:I

.field private waiting:Z


# direct methods
.method private constructor <init>(Landroid/app/Activity;Ljava/lang/Object;Ljava/lang/String;Ljava/util/List;ZJ)V
    .locals 1

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p3, p0, Lfixture/AutomaticCaller;->targetId:Ljava/lang/String;

    return-void
.end method

.method static synthetic access$next(Lfixture/AutomaticCaller;)V
    .locals 0

    invoke-direct {p0}, Lfixture/AutomaticCaller;->next()V

    return-void
.end method

.method static synthetic access$currentId(Lfixture/AutomaticCaller;)Ljava/lang/String;
    .locals 1

    iget-object v0, p0, Lfixture/AutomaticCaller;->currentId:Ljava/lang/String;

    return-object v0
.end method

.method static synthetic access$finished(Lfixture/AutomaticCaller;)Ljava/util/concurrent/atomic/AtomicBoolean;
    .locals 1

    iget-object v0, p0, Lfixture/AutomaticCaller;->finished:Ljava/util/concurrent/atomic/AtomicBoolean;

    return-object v0
.end method

.method static synthetic access$token(Lfixture/AutomaticCaller;)I
    .locals 1

    iget v0, p0, Lfixture/AutomaticCaller;->token:I

    return v0
.end method

.method static synthetic access$uncertain(Lfixture/AutomaticCaller;Ljava/lang/String;)V
    .locals 0

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->handleUncertainMutation(Ljava/lang/String;)V

    return-void
.end method

.method static synthetic access$waiting(Lfixture/AutomaticCaller;)Z
    .locals 1

    iget-boolean v0, p0, Lfixture/AutomaticCaller;->waiting:Z

    return v0
.end method

.method private handleCompletionPersistence(Ljava/lang/String;)V
    .locals 4

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->isCurrent(Ljava/lang/String;)Z

    move-result v0

    if-nez v0, :completion_persistence_current

    return-void

    :completion_persistence_current
    const/4 v0, 0x0

    iput-boolean v0, p0, Lfixture/AutomaticCaller;->waiting:Z

    iget-wide v1, p0, Lfixture/AutomaticCaller;->schedulerToken:J

    invoke-static {v1, v2, v0}, Lthreadsmod/autoblock/AutoBlockSync;->markSchedulerMutationInFlight(JZ)Z

    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v1, v2, p1}, Lthreadsmod/autoblock/AutoBlockSync;->quarantineCompletionReview(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z

    move-result v1

    const-string v2, "completion_persistence"

    const/4 v3, 0x1

    invoke-static {v2, v3, v0, v3, v1}, Lthreadsmod/autoblock/BlockDiagnostic;->forFailure(Ljava/lang/String;ZZZZ)Lthreadsmod/autoblock/BlockDiagnostic;

    move-result-object v0

    :try_completion_history_start
    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v1, v2, p1, v0}, Lthreadsmod/autoblock/ModStateStore;->recordAutomaticFailure(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)V
    :try_completion_history_end
    .catchall {:try_completion_history_start .. :try_completion_history_end} :catch_completion_history

    goto :completion_history_done

    :catch_completion_history
    move-exception p1

    :completion_history_done
    :try_completion_diagnostic_start
    iget-object p1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {p1, v1, v0}, Lthreadsmod/autoblock/ModStateStore;->recordFailureDiagnostic(Landroid/content/Context;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)V
    :try_completion_diagnostic_end
    .catchall {:try_completion_diagnostic_start .. :try_completion_diagnostic_end} :catch_completion_diagnostic

    goto :completion_diagnostic_done

    :catch_completion_diagnostic
    move-exception p1

    :completion_diagnostic_done
    :try_completion_log_start
    const-string p1, "ThreadsModAutoBlock"

    invoke-virtual {v0}, Lthreadsmod/autoblock/BlockDiagnostic;->logLine()Ljava/lang/String;

    move-result-object v1

    invoke-static {p1, v1}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I
    :try_completion_log_end
    .catchall {:try_completion_log_start .. :try_completion_log_end} :catch_completion_log

    goto :completion_log_done

    :catch_completion_log
    move-exception p1

    :completion_log_done
    invoke-virtual {v0}, Lthreadsmod/autoblock/BlockDiagnostic;->status()Ljava/lang/String;

    move-result-object p1

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    return-void
.end method

.method private handleFailure(Ljava/lang/String;Ljava/lang/String;)V
    .locals 4

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->isCurrent(Ljava/lang/String;)Z

    move-result v0

    if-nez v0, :failure_current

    return-void

    :failure_current
    const-string v0, "completion_persistence"

    invoke-virtual {v0, p2}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :failure_not_completion

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->handleCompletionPersistence(Ljava/lang/String;)V

    return-void

    :failure_not_completion
    const-string v0, "callback_timeout"

    invoke-virtual {v0, p2}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :failure_regular

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->handleUncertainMutation(Ljava/lang/String;)V

    return-void

    :failure_regular
    const/4 v0, 0x0

    iput-boolean v0, p0, Lfixture/AutomaticCaller;->waiting:Z

    iget-wide v1, p0, Lfixture/AutomaticCaller;->schedulerToken:J

    invoke-static {v1, v2, v0}, Lthreadsmod/autoblock/AutoBlockSync;->markSchedulerMutationInFlight(JZ)Z

    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v1, v2}, Lthreadsmod/autoblock/AutoBlockSync;->persistRetryDeadline(Landroid/content/Context;Ljava/lang/String;)Z

    move-result v1

    const/4 v2, 0x1

    iget-boolean v3, p0, Lfixture/AutomaticCaller;->started:Z

    invoke-static {p2, v2, v0, v3, v1}, Lthreadsmod/autoblock/BlockDiagnostic;->forFailure(Ljava/lang/String;ZZZZ)Lthreadsmod/autoblock/BlockDiagnostic;

    move-result-object p2

    iget-object v0, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v0, v1, p1, p2}, Lthreadsmod/autoblock/ModStateStore;->recordAutomaticFailure(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)V

    iget-object p1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v0, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {p1, v0, p2}, Lthreadsmod/autoblock/ModStateStore;->recordFailureDiagnostic(Landroid/content/Context;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)V

    const-string p1, "ThreadsModAutoBlock"

    invoke-virtual {p2}, Lthreadsmod/autoblock/BlockDiagnostic;->logLine()Ljava/lang/String;

    move-result-object v0

    invoke-static {p1, v0}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    invoke-virtual {p2}, Lthreadsmod/autoblock/BlockDiagnostic;->status()Ljava/lang/String;

    move-result-object p1

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    const-wide/32 p1, 0x1d8a8

    invoke-static {p1, p2}, Lthreadsmod/autoblock/AutoBlockSync;->scheduleManualDrain(J)V

    return-void
.end method

.method private handleUncertainMutation(Ljava/lang/String;)V
    .locals 5

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->isCurrent(Ljava/lang/String;)Z

    move-result v0

    if-nez v0, :current

    return-void

    :current
    const/4 v0, 0x0

    iput-boolean v0, p0, Lfixture/AutomaticCaller;->waiting:Z

    iget-wide v1, p0, Lfixture/AutomaticCaller;->schedulerToken:J

    invoke-static {v1, v2, v0}, Lthreadsmod/autoblock/AutoBlockSync;->markSchedulerMutationInFlight(JZ)Z

    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v1, v2, p1}, Lthreadsmod/autoblock/AutoBlockSync;->quarantineCompletionReview(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z

    move-result v1

    const/4 v2, 0x1

    iget-boolean v3, p0, Lfixture/AutomaticCaller;->started:Z

    const-string v4, "callback_timeout"

    invoke-static {v4, v2, v0, v3, v1}, Lthreadsmod/autoblock/BlockDiagnostic;->forFailure(Ljava/lang/String;ZZZZ)Lthreadsmod/autoblock/BlockDiagnostic;

    move-result-object v0

    :try_automatic_history_start
    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v1, v2, p1, v0}, Lthreadsmod/autoblock/ModStateStore;->recordAutomaticFailure(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)V
    :try_automatic_history_end
    .catchall {:try_automatic_history_start .. :try_automatic_history_end} :catch_automatic_history

    goto :automatic_history_done

    :catch_automatic_history
    move-exception p1

    :automatic_history_done
    :try_diagnostic_history_start
    iget-object p1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {p1, v1, v0}, Lthreadsmod/autoblock/ModStateStore;->recordFailureDiagnostic(Landroid/content/Context;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)V
    :try_diagnostic_history_end
    .catchall {:try_diagnostic_history_start .. :try_diagnostic_history_end} :catch_diagnostic_history

    goto :diagnostic_history_done

    :catch_diagnostic_history
    move-exception p1

    :diagnostic_history_done
    :try_diagnostic_log_start
    const-string p1, "ThreadsModAutoBlock"

    invoke-virtual {v0}, Lthreadsmod/autoblock/BlockDiagnostic;->logLine()Ljava/lang/String;

    move-result-object v1

    invoke-static {p1, v1}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I
    :try_diagnostic_log_end
    .catchall {:try_diagnostic_log_start .. :try_diagnostic_log_end} :catch_diagnostic_log

    goto :diagnostic_log_done

    :catch_diagnostic_log
    move-exception p1

    :diagnostic_log_done
    invoke-virtual {v0}, Lthreadsmod/autoblock/BlockDiagnostic;->status()Ljava/lang/String;

    move-result-object p1

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    return-void
.end method

.method private finish(Ljava/lang/String;)V
    .locals 17

    move-object/from16 v1, p0

    iget-object v0, v1, Lfixture/AutomaticCaller;->finished:Ljava/util/concurrent/atomic/AtomicBoolean;

    const/4 v2, 0x1

    const/4 v3, 0x0

    invoke-virtual {v0, v3, v2}, Ljava/util/concurrent/atomic/AtomicBoolean;->compareAndSet(ZZ)Z

    move-result v0

    if-nez v0, :finish_effects

    return-void

    :finish_effects
    iput-boolean v3, v1, Lfixture/AutomaticCaller;->waiting:Z

    :try_finish_status_start
    iget-object v0, v1, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, v1, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    move-object/from16 v3, p1

    invoke-static {v0, v2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V
    :try_finish_status_end
    .catchall {:try_finish_status_start .. :try_finish_status_end} :catch_finish_status

    iget-wide v3, v1, Lfixture/AutomaticCaller;->schedulerToken:J

    iget-object v5, v1, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v6, v1, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    const-wide/16 v7, 0x0

    const/4 v9, 0x0

    invoke-static/range {v3 .. v9}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V

    goto :finish_return

    :catch_finish_status
    move-exception v0

    iget-wide v10, v1, Lfixture/AutomaticCaller;->schedulerToken:J

    iget-object v12, v1, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v13, v1, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    const-wide/16 v14, 0x0

    const/16 v16, 0x0

    invoke-static/range {v10 .. v16}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V

    :finish_return
    nop

    return-void
.end method

.method private finishAndResume(Ljava/lang/String;J)V
    .locals 0

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    return-void
.end method

.method private finishForForegroundChange(Ljava/lang/String;Z)V
    .locals 17

    move-object/from16 v1, p0

    iget-object v0, v1, Lfixture/AutomaticCaller;->finished:Ljava/util/concurrent/atomic/AtomicBoolean;

    const/4 v2, 0x1

    const/4 v3, 0x0

    invoke-virtual {v0, v3, v2}, Ljava/util/concurrent/atomic/AtomicBoolean;->compareAndSet(ZZ)Z

    move-result v0

    if-nez v0, :foreground_finish_effects

    return-void

    :foreground_finish_effects
    iput-boolean v3, v1, Lfixture/AutomaticCaller;->waiting:Z

    if-eqz p2, :try_foreground_status_start

    iget-object v0, v1, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v0}, Lthreadsmod/autoblock/AutoBlockSync;->requestForceRefresh(Ljava/lang/String;)Z

    :try_foreground_status_start
    iget-object v0, v1, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, v1, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    move-object/from16 v3, p1

    invoke-static {v0, v2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V
    :try_foreground_status_end
    .catchall {:try_foreground_status_start .. :try_foreground_status_end} :catch_foreground_status

    iget-wide v3, v1, Lfixture/AutomaticCaller;->schedulerToken:J

    iget-object v5, v1, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v6, v1, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    const-wide/16 v7, 0x0

    const/4 v9, 0x1

    invoke-static/range {v3 .. v9}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V

    goto :foreground_finish_return

    :catch_foreground_status
    move-exception v0

    iget-wide v10, v1, Lfixture/AutomaticCaller;->schedulerToken:J

    iget-object v12, v1, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v13, v1, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    const-wide/16 v14, 0x0

    const/16 v16, 0x1

    invoke-static/range {v10 .. v16}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V

    :foreground_finish_return
    nop

    return-void
.end method

.method private isCurrentForeground()Z
    .locals 3

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->access$foreground()Z

    move-result v0

    const/4 v1, 0x0

    if-eqz v0, :foreground_false

    iget-object v0, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    invoke-static {v0}, Lthreadsmod/autoblock/AutoBlockSync;->isEnabled(Landroid/content/Context;)Z

    move-result v0

    if-nez v0, :foreground_enabled

    goto :foreground_false

    :foreground_enabled
    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->access$currentActivity()Ljava/lang/ref/WeakReference;

    move-result-object v0

    invoke-virtual {v0}, Ljava/lang/ref/WeakReference;->get()Ljava/lang/Object;

    move-result-object v0

    check-cast v0, Landroid/app/Activity;

    iget-object v2, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    if-ne v0, v2, :activity_not_current

    iget-object v0, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    invoke-virtual {v0}, Landroid/app/Activity;->isFinishing()Z

    move-result v0

    if-nez v0, :activity_not_current

    iget-object v0, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    invoke-virtual {v0}, Landroid/app/Activity;->isDestroyed()Z

    move-result v0

    if-eqz v0, :activity_alive

    goto :activity_not_current

    :activity_alive
    iget-object v0, p0, Lfixture/AutomaticCaller;->userSession:Ljava/lang/Object;

    invoke-static {v0}, Lthreadsmod/autoblock/AutoBlockSync;->access$viewerId(Ljava/lang/Object;)Ljava/lang/String;

    move-result-object v0

    iget-object v2, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-virtual {v2, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :identity_done

    iget-object v0, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->access$currentViewer()Ljava/lang/String;

    move-result-object v2

    invoke-virtual {v0, v2}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :identity_done

    const/4 v1, 0x1

    :identity_done
    return v1

    :activity_not_current
    return v1

    :foreground_false
    return v1
.end method

.method private isCurrent(Ljava/lang/String;)Z
    .locals 2

    iget-object v0, p0, Lfixture/AutomaticCaller;->finished:Ljava/util/concurrent/atomic/AtomicBoolean;

    invoke-virtual {v0}, Ljava/util/concurrent/atomic/AtomicBoolean;->get()Z

    move-result v0

    if-nez v0, :not_current

    iget-wide v0, p0, Lfixture/AutomaticCaller;->schedulerToken:J

    invoke-static {v0, v1}, Lthreadsmod/autoblock/AutoBlockSync;->isSchedulerOwner(J)Z

    move-result v0

    if-eqz v0, :not_current

    iget-boolean v0, p0, Lfixture/AutomaticCaller;->waiting:Z

    if-eqz v0, :not_current

    iget-object v0, p0, Lfixture/AutomaticCaller;->targetId:Ljava/lang/String;

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

.method private next()V
    .locals 0

    return-void
.end method


# virtual methods
.method public begin()V
    .locals 10

    iget-object v2, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v3, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->millisUntilPaceAllowed(Landroid/content/Context;Ljava/lang/String;)J

    move-result-wide v2

    const-wide/16 v4, 0x0

    cmp-long v6, v2, v4

    if-lez v6, :pre_pace_accepted

    iget v4, p0, Lfixture/AutomaticCaller;->token:I

    add-int/lit8 v4, v4, 0x1

    iput v4, p0, Lfixture/AutomaticCaller;->token:I

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->access$main()Landroid/os/Handler;

    move-result-object v0

    new-instance v1, Lfixture/AutomaticCaller$PrePaceRunnable;

    invoke-direct {v1, p0, v4}, Lfixture/AutomaticCaller$PrePaceRunnable;-><init>(Lfixture/AutomaticCaller;I)V

    invoke-virtual {v0, v1, v2, v3}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    move-result v0

    if-nez v0, :pre_pace_post_accepted

    const-string v0, "Scheduler wake was rejected; reopen Threads to resume safely."

    invoke-direct {p0, v0}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    return-void

    :pre_pace_post_accepted
    return-void

    :pre_pace_accepted
    iget-object v0, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v0, v1}, Lthreadsmod/autoblock/AutoBlockSync;->doneIds(Landroid/content/Context;Ljava/lang/String;)Ljava/util/Set;

    move-result-object v5

    if-nez v5, :done_ids_valid

    const-string v0, "Completed-target state needs review; automatic work remains paused."

    invoke-direct {p0, v0}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    return-void

    :done_ids_valid

    const/4 v7, 0x1

    const/4 v8, 0x0

    invoke-static {v0, v1}, Lthreadsmod/autoblock/ModStateStore;->completionReviewState(Landroid/content/Context;Ljava/lang/String;)Lthreadsmod/autoblock/ModStateStore$CompletionReviewState;

    move-result-object v6

    iget-boolean v0, v6, Lthreadsmod/autoblock/ModStateStore$CompletionReviewState;->valid:Z

    if-eqz v0, :selection_review_failure

    iget-boolean v0, v6, Lthreadsmod/autoblock/ModStateStore$CompletionReviewState;->full:Z

    if-nez v0, :selection_review_failure

    iget-object v0, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v0}, Lthreadsmod/autoblock/AutoBlockSync;->isLocalCompletionReviewPaused(Ljava/lang/String;)Z

    move-result v0

    if-eqz v0, :selection_entry

    goto :selection_review_failure

    :selection_entry
    nop

    :selection_loop
    iget v0, p0, Lfixture/AutomaticCaller;->index:I

    iget-object v1, p0, Lfixture/AutomaticCaller;->targets:Ljava/util/List;

    invoke-interface {v1}, Ljava/util/List;->size()I

    move-result v2

    if-ge v0, v2, :selection_exhausted

    iget-object v1, p0, Lfixture/AutomaticCaller;->targets:Ljava/util/List;

    iget v0, p0, Lfixture/AutomaticCaller;->index:I

    add-int/lit8 v2, v0, 0x1

    iput v2, p0, Lfixture/AutomaticCaller;->index:I

    invoke-interface {v1, v0}, Ljava/util/List;->get(I)Ljava/lang/Object;

    move-result-object v3

    check-cast v3, Ljava/lang/String;

    iget-object v4, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-virtual {v3, v4}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v4

    if-nez v4, :selection_rejected

    invoke-interface {v5, v3}, Ljava/util/Set;->contains(Ljava/lang/Object;)Z

    move-result v4

    if-nez v4, :selection_rejected

    iget-object v4, v6, Lthreadsmod/autoblock/ModStateStore$CompletionReviewState;->targets:Ljava/util/Set;

    invoke-interface {v4, v3}, Ljava/util/Set;->contains(Ljava/lang/Object;)Z

    move-result v4

    if-nez v4, :selection_rejected

    nop

    goto :selection_join

    :selection_rejected
    goto :selection_loop

    :selection_exhausted
    const/4 v3, 0x0

    :selection_join
    if-nez v3, :selection_present

    const/4 v0, 0x0

    if-eqz v0, :selection_empty

    const-string v0, "Target budget complete."

    invoke-direct {p0, v0}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    return-void

    :selection_empty
    const-string v0, "Verified list contains no eligible targets."

    invoke-direct {p0, v0}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    return-void

    :selection_present
    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->access$passiveAdmissionLock()Ljava/lang/Object;

    move-result-object v9

    monitor-enter v9

    :try_passive_admission_start
    iget-object v0, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v0, v1, v3}, Lthreadsmod/autoblock/AutoBlockSync;->currentPassiveMatch(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;

    move-result-object v0

    iget-boolean v1, v0, Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;->storeValid:Z

    if-nez v1, :passive_store_current

    const-string v0, "Indexed-list storage needs a verified replacement; passive blocking is paused."

    invoke-direct {p0, v0}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    monitor-exit v9

    return-void

    :passive_store_current
    iget-boolean v0, v0, Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;->matched:Z

    if-nez v0, :passive_match_current

    const-string v0, "The selected profile is no longer a current visible match."

    const-wide/16 v1, 0x0

    invoke-direct {p0, v0, v1, v2}, Lfixture/AutomaticCaller;->finishAndResume(Ljava/lang/String;J)V

    monitor-exit v9

    return-void

    :passive_match_current
    iget-object v0, p0, Lfixture/AutomaticCaller;->userSession:Ljava/lang/Object;

    invoke-static {v0, v3}, Lthreadsmod/autoblock/ThreadsBlockBridge;->passivePreflight(Ljava/lang/Object;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0

    iget-object v0, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    const/4 v1, 0x5

    invoke-static {v0, v3, v1}, Lthreadsmod/autoblock/AutoBlockSync;->admitForegroundPassiveTarget(Ljava/lang/String;Ljava/lang/String;I)Z

    move-result v0

    if-nez v0, :passive_match_admitted

    monitor-exit v9

    return-void

    :passive_match_admitted
    iget-object v0, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v0, v1, v3}, Lthreadsmod/autoblock/ModStateStore;->markPassiveRunning(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z

    move-result v0

    if-nez v0, :passive_running_persisted

    monitor-exit v9

    return-void

    :passive_running_persisted
    iput-object v3, p0, Lfixture/AutomaticCaller;->currentId:Ljava/lang/String;

    iput-boolean v7, p0, Lfixture/AutomaticCaller;->waiting:Z

    iput-boolean v8, p0, Lfixture/AutomaticCaller;->started:Z

    iget-object v0, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v0, v1, v7}, Lthreadsmod/autoblock/AutoBlockSync;->reserveAttempt(Landroid/content/Context;Ljava/lang/String;Z)Z

    move-result v0

    if-nez v0, :reservation_succeeded

    iput-boolean v8, p0, Lfixture/AutomaticCaller;->waiting:Z

    iget-object v0, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v0, v1}, Lthreadsmod/autoblock/AutoBlockSync;->persistRetryDeadline(Landroid/content/Context;Ljava/lang/String;)Z

    move-result v0

    const-string v1, "attempt_reservation"

    invoke-static {v1, v7, v8, v8, v0}, Lthreadsmod/autoblock/BlockDiagnostic;->forFailure(Ljava/lang/String;ZZZZ)Lthreadsmod/autoblock/BlockDiagnostic;

    move-result-object v0

    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v4, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v1, v4, v3, v0}, Lthreadsmod/autoblock/ModStateStore;->recordAutomaticFailure(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)V

    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v4, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v1, v4, v0}, Lthreadsmod/autoblock/ModStateStore;->recordFailureDiagnostic(Landroid/content/Context;Ljava/lang/String;Lthreadsmod/autoblock/BlockDiagnostic;)V

    const-string v1, "ThreadsModAutoBlock"

    invoke-virtual {v0}, Lthreadsmod/autoblock/BlockDiagnostic;->logLine()Ljava/lang/String;

    move-result-object v4

    invoke-static {v1, v4}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    invoke-virtual {v0}, Lthreadsmod/autoblock/BlockDiagnostic;->status()Ljava/lang/String;

    move-result-object v1

    invoke-direct {p0, v1}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    const-wide/32 v0, 0x1d8a8

    invoke-static {v0, v1}, Lthreadsmod/autoblock/AutoBlockSync;->scheduleManualDrain(J)V

    monitor-exit v9

    return-void

    :reservation_succeeded
    iget v0, p0, Lfixture/AutomaticCaller;->attemptsThisRun:I

    add-int/2addr v0, v7

    iput v0, p0, Lfixture/AutomaticCaller;->attemptsThisRun:I

    iget-object v0, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    const-string v4, "Blocking selected target."

    invoke-static {v0, v1, v4}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    iget-wide v0, p0, Lfixture/AutomaticCaller;->schedulerToken:J

    invoke-static {v0, v1, v7}, Lthreadsmod/autoblock/AutoBlockSync;->markSchedulerMutationInFlight(JZ)Z

    move-result v0

    if-nez v0, :try_bridge_start

    iput-boolean v8, p0, Lfixture/AutomaticCaller;->waiting:Z

    const-string v0, "Blocking moved to the current Threads screen."

    iget-boolean v1, p0, Lfixture/AutomaticCaller;->forceRefresh:Z

    invoke-direct {p0, v0, v1}, Lfixture/AutomaticCaller;->finishForForegroundChange(Ljava/lang/String;Z)V

    monitor-exit v9

    return-void

    :try_passive_admission_end
    .catchall {:try_passive_admission_start .. :try_passive_admission_end} :catch_passive_admission

    :try_bridge_start
    iget-object v0, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v1, p0, Lfixture/AutomaticCaller;->userSession:Ljava/lang/Object;

    invoke-static {v0, v1, v3, p0}, Lthreadsmod/autoblock/ThreadsBlockBridge;->block(Landroid/app/Activity;Ljava/lang/Object;Ljava/lang/String;Lthreadsmod/autoblock/BridgeCallback;)V
    :try_bridge_end
    .catchall {:try_bridge_start .. :try_bridge_end} :catch_bridge

    :try_passive_exit_start
    monitor-exit v9
    :try_passive_exit_end
    .catchall {:try_passive_exit_start .. :try_passive_exit_end} :catch_passive_admission

    move-object v5, v3

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->access$main()Landroid/os/Handler;

    move-result-object v0

    iget v2, p0, Lfixture/AutomaticCaller;->token:I

    add-int/lit8 v2, v2, 0x1

    iput v2, p0, Lfixture/AutomaticCaller;->token:I

    new-instance v1, Lfixture/AutomaticCaller$WatchdogRunnable;

    invoke-direct {v1, p0, v2}, Lfixture/AutomaticCaller$WatchdogRunnable;-><init>(Lfixture/AutomaticCaller;I)V

    const-wide/32 v2, 0xafc8

    invoke-virtual {v0, v1, v2, v3}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    move-result v0

    if-nez v0, :watchdog_accepted

    invoke-direct {p0, v5}, Lfixture/AutomaticCaller;->handleUncertainMutation(Ljava/lang/String;)V

    :watchdog_accepted
    return-void

    :catch_bridge
    move-exception v0

    :try_bridge_handler_start
    const-string v0, "bridge_exception"

    invoke-direct {p0, v3, v0}, Lfixture/AutomaticCaller;->handleFailure(Ljava/lang/String;Ljava/lang/String;)V

    monitor-exit v9
    :try_bridge_handler_end
    .catchall {:try_bridge_handler_start .. :try_bridge_handler_end} :catch_passive_admission

    return-void

    :catch_passive_admission
    move-exception v0

    monitor-exit v9

    throw v0

    :selection_review_failure
    const-string v0, "Completion-review state needs attention; automatic work remains paused."

    invoke-direct {p0, v0}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    return-void
.end method

.method public onBridgeFailure(Ljava/lang/String;Ljava/lang/String;)V
    .locals 0

    invoke-direct {p0, p1, p2}, Lfixture/AutomaticCaller;->handleFailure(Ljava/lang/String;Ljava/lang/String;)V

    return-void
.end method

.method public onBridgeStarted(Ljava/lang/String;)V
    .locals 4

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->isCurrent(Ljava/lang/String;)Z

    move-result v0

    if-nez v0, :current

    return-void

    :current

    const/4 v0, 0x1

    iput-boolean v0, p0, Lfixture/AutomaticCaller;->started:Z

    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    const-string v3, "Blocking selected target..."

    invoke-static {v1, v2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    :done
    return-void
.end method

.method public onBridgeSuccess(Ljava/lang/String;)V
    .locals 7

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->isCurrent(Ljava/lang/String;)Z

    move-result v0

    if-nez v0, :current

    return-void

    :current

    const/4 v6, 0x0

    :try_completion_save_start
    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v1, v2, p1}, Lthreadsmod/autoblock/AutoBlockSync;->markDone(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z

    move-result v0
    :try_completion_save_end
    .catchall {:try_completion_save_start .. :try_completion_save_end} :catch_completion_save

    goto :completion_save_join

    :catch_completion_save
    move-exception v3

    move v0, v6

    :completion_save_join
    if-nez v0, :completion_saved

    invoke-direct {p0, p1}, Lfixture/AutomaticCaller;->handleCompletionPersistence(Ljava/lang/String;)V

    return-void

    :completion_saved
    iget-wide v3, p0, Lfixture/AutomaticCaller;->schedulerToken:J

    const/4 v5, 0x0

    invoke-static {v3, v4, v5}, Lthreadsmod/autoblock/AutoBlockSync;->markSchedulerMutationInFlight(JZ)Z

    const/4 v0, 0x0

    :try_success_record_start
    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v1, v2, p1}, Lthreadsmod/autoblock/ModStateStore;->recordAutomaticBlocked(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V
    :try_success_record_end
    .catchall {:try_success_record_start .. :try_success_record_end} :catch_success_record

    goto :success_record_join

    :catch_success_record
    move-exception v6

    :success_record_join
    iput-boolean v0, p0, Lfixture/AutomaticCaller;->waiting:Z

    :try_clear_retry_start
    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v1, v2}, Lthreadsmod/autoblock/AutoBlockSync;->clearRetryDeadline(Landroid/content/Context;Ljava/lang/String;)Z
    :try_clear_retry_end
    .catchall {:try_clear_retry_start .. :try_clear_retry_end} :catch_clear_retry

    goto :clear_retry_done

    :catch_clear_retry
    move-exception v1

    :clear_retry_done
    iget v1, p0, Lfixture/AutomaticCaller;->successesThisRun:I

    add-int/lit8 v1, v1, 0x1

    iput v1, p0, Lfixture/AutomaticCaller;->successesThisRun:I

    :try_success_status_start
    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    new-instance v3, Ljava/lang/StringBuilder;

    invoke-direct {v3}, Ljava/lang/StringBuilder;-><init>()V

    const-string v4, "Synchronized "

    invoke-virtual {v3, v4}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v3

    iget v4, p0, Lfixture/AutomaticCaller;->successesThisRun:I

    invoke-virtual {v3, v4}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    move-result-object v3

    const-string v4, " account(s) in this run."

    invoke-virtual {v3, v4}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v3

    invoke-virtual {v3}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v3

    invoke-static {v1, v2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V
    :try_success_status_end
    .catchall {:try_success_status_start .. :try_success_status_end} :catch_success_status

    goto :success_status_done

    :catch_success_status
    move-exception v1

    :success_status_done
    :try_reviewed_terminal_start
    const/4 v0, 0x0

    if-eqz v0, :choose_pace_or_foreground

    const-string v0, "Run cap reached."

    invoke-direct {p0, v0}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    return-void

    :choose_pace_or_foreground
    const/4 v0, 0x0

    if-eqz v0, :foreground_terminal

    iget-object v1, p0, Lfixture/AutomaticCaller;->activity:Landroid/app/Activity;

    iget-object v2, p0, Lfixture/AutomaticCaller;->viewer:Ljava/lang/String;

    invoke-static {v1, v2}, Lthreadsmod/autoblock/AutoBlockSync;->millisUntilPaceAllowed(Landroid/content/Context;Ljava/lang/String;)J

    move-result-wide v3

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->access$main()Landroid/os/Handler;

    move-result-object v5

    new-instance v6, Lfixture/AutomaticCaller$NextRunnable;

    invoke-direct {v6, p0}, Lfixture/AutomaticCaller$NextRunnable;-><init>(Lfixture/AutomaticCaller;)V

    invoke-virtual {v5, v6, v3, v4}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    move-result v5

    if-nez v5, :terminal_return

    const-string v0, "Scheduler wake was rejected; reopen Threads to resume safely."

    invoke-direct {p0, v0}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    goto :terminal_return

    :foreground_terminal
    const-string v0, "Block completed on another Threads screen."

    const/4 v1, 0x0

    invoke-direct {p0, v0, v1}, Lfixture/AutomaticCaller;->finishForForegroundChange(Ljava/lang/String;Z)V
    :try_reviewed_terminal_end
    .catchall {:try_reviewed_terminal_start .. :try_reviewed_terminal_end} :catch_reviewed_terminal

    goto :terminal_return

    :catch_reviewed_terminal
    move-exception v0

    const-string v0, "Block completed; local scheduler state needs review."

    invoke-direct {p0, v0}, Lfixture/AutomaticCaller;->finish(Ljava/lang/String;)V

    return-void

    :terminal_return
    return-void
.end method
