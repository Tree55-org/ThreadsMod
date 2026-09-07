.class public final Lthreadsmod/autoblock/AutoBlockSync;
.super Ljava/lang/Object;
.source "AutoBlockSync.java"


# static fields
.field static final MAIN:Landroid/os/Handler;

.field private static final PASSIVE_ADMISSION_LOCK:Ljava/lang/Object;

.field private static final RUNNING:Ljava/util/concurrent/atomic/AtomicBoolean;

.field private static final SCHEDULER_LOCK:Ljava/lang/Object;

.field private static currentActivity:Ljava/lang/ref/WeakReference;

.field private static schedulerMutationInFlight:Z

.field private static schedulerOwnerActivity:Ljava/lang/ref/WeakReference;

.field private static schedulerOwnerForceRefresh:Z

.field private static schedulerOwnerToken:J

.field private static schedulerOwnerViewer:Ljava/lang/String;

.field private static currentSession:Ljava/lang/Object;

.field private static currentViewer:Ljava/lang/String;

.field private static foreground:Z


# direct methods
.method static constructor <clinit>()V
    .locals 2

    new-instance v0, Landroid/os/Handler;

    invoke-static {}, Landroid/os/Looper;->getMainLooper()Landroid/os/Looper;

    move-result-object v1

    invoke-direct {v0, v1}, Landroid/os/Handler;-><init>(Landroid/os/Looper;)V

    sput-object v0, Lthreadsmod/autoblock/AutoBlockSync;->MAIN:Landroid/os/Handler;

    new-instance v0, Ljava/lang/Object;

    invoke-direct {v0}, Ljava/lang/Object;-><init>()V

    sput-object v0, Lthreadsmod/autoblock/AutoBlockSync;->PASSIVE_ADMISSION_LOCK:Ljava/lang/Object;

    return-void
.end method

.method private constructor <init>()V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method private static currentPassiveMatch(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;
    .locals 7

    invoke-static {p1, p2}, Lthreadsmod/autoblock/AutoBlockSync;->hasVisibleRegistrationLocked(Ljava/lang/String;Ljava/lang/String;)Z

    move-result v0

    if-nez v0, :visible_generation

    const/4 v0, 0x1

    const/4 v1, 0x0

    new-instance v2, Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;

    invoke-direct {v2, v0, v1}, Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;-><init>(ZZ)V

    return-object v2

    :visible_generation
    invoke-static {p1, p2}, Lthreadsmod/autoblock/AutoBlockSync;->matchedGeneration(Ljava/lang/String;Ljava/lang/String;)J

    move-result-wide v0

    invoke-static {p0, p2, v0, v1}, Lthreadsmod/autoblock/BlocklistStore;->isCurrentIdMatch(Landroid/content/Context;Ljava/lang/String;J)Lthreadsmod/autoblock/BlocklistStore$IdMatch;

    move-result-object v2

    iget-boolean v3, v2, Lthreadsmod/autoblock/BlocklistStore$IdMatch;->storeValid:Z

    if-nez v3, :valid_store

    iget-wide v0, v2, Lthreadsmod/autoblock/BlocklistStore$IdMatch;->generation:J

    invoke-static {p0, p1, v0, v1}, Lthreadsmod/autoblock/AutoBlockSync;->latchPassiveStorePause(Landroid/content/Context;Ljava/lang/String;J)V

    const/4 v3, 0x0

    new-instance v6, Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;

    invoke-direct {v6, v3, v3}, Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;-><init>(ZZ)V

    return-object v6

    :valid_store
    const/4 v4, 0x1

    const/4 v5, 0x0

    iget-boolean v3, v2, Lthreadsmod/autoblock/BlocklistStore$IdMatch;->matched:Z

    if-eqz v3, :not_current

    invoke-static {p1, p2}, Lthreadsmod/autoblock/AutoBlockSync;->hasVisibleRegistrationLocked(Ljava/lang/String;Ljava/lang/String;)Z

    move-result v3

    if-eqz v3, :not_current

    iget-object v3, v2, Lthreadsmod/autoblock/BlocklistStore$IdMatch;->username:Ljava/lang/String;

    invoke-static {p1, p2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->visibleUsernameMatchesStoredLocked(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z

    move-result v3

    if-eqz v3, :not_current

    move v5, v4

    goto :construct_result

    :not_current
    nop

    :construct_result
    new-instance v6, Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;

    invoke-direct {v6, v4, v5}, Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;-><init>(ZZ)V

    return-object v6
.end method

.method public static synthetic access$passiveAdmissionLock()Ljava/lang/Object;
    .locals 1

    sget-object v0, Lthreadsmod/autoblock/AutoBlockSync;->PASSIVE_ADMISSION_LOCK:Ljava/lang/Object;

    return-object v0
.end method

.method public static synthetic access$currentActivity()Ljava/lang/ref/WeakReference;
    .locals 1

    sget-object v0, Lthreadsmod/autoblock/AutoBlockSync;->currentActivity:Ljava/lang/ref/WeakReference;

    return-object v0
.end method

.method public static synthetic access$currentViewer()Ljava/lang/String;
    .locals 1

    sget-object v0, Lthreadsmod/autoblock/AutoBlockSync;->currentViewer:Ljava/lang/String;

    return-object v0
.end method

.method public static synthetic access$foreground()Z
    .locals 1

    sget-boolean v0, Lthreadsmod/autoblock/AutoBlockSync;->foreground:Z

    return v0
.end method

.method public static synthetic access$main()Landroid/os/Handler;
    .locals 1

    sget-object v0, Lthreadsmod/autoblock/AutoBlockSync;->MAIN:Landroid/os/Handler;

    return-object v0
.end method

.method public static synthetic access$viewerId(Ljava/lang/Object;)Ljava/lang/String;
    .locals 0

    invoke-static {p0}, Lthreadsmod/autoblock/AutoBlockSync;->viewerId(Ljava/lang/Object;)Ljava/lang/String;

    move-result-object p0

    return-object p0
.end method

.method public static isSchedulerOwner(J)Z
    .locals 3

    sget-object v0, Lthreadsmod/autoblock/AutoBlockSync;->SCHEDULER_LOCK:Ljava/lang/Object;

    monitor-enter v0

    const-wide/16 v1, 0x0

    cmp-long v1, p0, v1

    if-eqz v1, :not_owner

    :try_owner_start
    sget-object v1, Lthreadsmod/autoblock/AutoBlockSync;->RUNNING:Ljava/util/concurrent/atomic/AtomicBoolean;

    invoke-virtual {v1}, Ljava/util/concurrent/atomic/AtomicBoolean;->get()Z

    move-result v1

    if-eqz v1, :not_owner

    sget-wide v1, Lthreadsmod/autoblock/AutoBlockSync;->schedulerOwnerToken:J

    cmp-long p0, v1, p0

    if-nez p0, :not_owner

    const/4 p0, 0x1

    goto :owner_join

    :catch_owner
    move-exception p0

    goto :owner_throw

    :not_owner
    const/4 p0, 0x0

    :owner_join
    monitor-exit v0

    return p0

    :owner_throw
    monitor-exit v0
    :try_owner_end
    .catchall {:try_owner_start .. :try_owner_end} :catch_owner

    throw p0
.end method

.method public static markSchedulerMutationInFlight(JZ)Z
    .locals 3

    sget-object v0, Lthreadsmod/autoblock/AutoBlockSync;->SCHEDULER_LOCK:Ljava/lang/Object;

    monitor-enter v0

    const-wide/16 v1, 0x0

    cmp-long v1, p0, v1

    if-eqz v1, :mark_rejected

    :try_mark_start
    sget-object v1, Lthreadsmod/autoblock/AutoBlockSync;->RUNNING:Ljava/util/concurrent/atomic/AtomicBoolean;

    invoke-virtual {v1}, Ljava/util/concurrent/atomic/AtomicBoolean;->get()Z

    move-result v1

    if-eqz v1, :mark_rejected

    sget-wide v1, Lthreadsmod/autoblock/AutoBlockSync;->schedulerOwnerToken:J

    cmp-long p0, v1, p0

    if-eqz p0, :mark_matched

    goto :mark_rejected

    :mark_matched
    sput-boolean p2, Lthreadsmod/autoblock/AutoBlockSync;->schedulerMutationInFlight:Z

    monitor-exit v0

    const/4 p0, 0x1

    return p0

    :mark_rejected
    monitor-exit v0

    const/4 p0, 0x0

    return p0

    :catch_mark
    move-exception p0

    monitor-exit v0
    :try_mark_end
    .catchall {:try_mark_start .. :try_mark_end} :catch_mark

    throw p0
.end method

.method private static releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V
    .locals 4

    sget-object v0, Lthreadsmod/autoblock/AutoBlockSync;->SCHEDULER_LOCK:Ljava/lang/Object;

    monitor-enter v0

    :try_release_start
    sget-wide v1, Lthreadsmod/autoblock/AutoBlockSync;->schedulerOwnerToken:J

    cmp-long v1, v1, p0

    if-nez v1, :stale_owner

    const-wide/16 v1, 0x0

    cmp-long p0, p0, v1

    if-nez p0, :release_owner

    goto :stale_owner

    :release_owner
    sput-wide v1, Lthreadsmod/autoblock/AutoBlockSync;->schedulerOwnerToken:J

    const-string p0, ""

    sput-object p0, Lthreadsmod/autoblock/AutoBlockSync;->schedulerOwnerViewer:Ljava/lang/String;

    new-instance p0, Ljava/lang/ref/WeakReference;

    const/4 p1, 0x0

    invoke-direct {p0, p1}, Ljava/lang/ref/WeakReference;-><init>(Ljava/lang/Object;)V

    sput-object p0, Lthreadsmod/autoblock/AutoBlockSync;->schedulerOwnerActivity:Ljava/lang/ref/WeakReference;

    const/4 p0, 0x0

    sput-boolean p0, Lthreadsmod/autoblock/AutoBlockSync;->schedulerMutationInFlight:Z

    sput-boolean p0, Lthreadsmod/autoblock/AutoBlockSync;->schedulerOwnerForceRefresh:Z

    sget-object p1, Lthreadsmod/autoblock/AutoBlockSync;->RUNNING:Ljava/util/concurrent/atomic/AtomicBoolean;

    invoke-virtual {p1, p0}, Ljava/util/concurrent/atomic/AtomicBoolean;->set(Z)V

    monitor-exit v0
    :try_release_end
    .catchall {:try_release_start .. :try_release_end} :catch_release

    invoke-static {p3}, Lthreadsmod/autoblock/AutoBlockSync;->isDecimalId(Ljava/lang/String;)Z

    move-result p1

    if-eqz p1, :release_return

    invoke-virtual {p3}, Ljava/lang/String;->length()I

    move-result p1

    const/16 v0, 0x18

    if-le p1, v0, :load_release_context

    goto :release_return

    :load_release_context
    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->getForegroundActivity()Landroid/app/Activity;

    move-result-object p1

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->getCurrentViewer()Ljava/lang/String;

    move-result-object v0

    sget-object v3, Lthreadsmod/autoblock/AutoBlockSync;->currentSession:Ljava/lang/Object;

    if-eqz p1, :release_return

    if-eqz v0, :release_return

    if-eqz v3, :release_return

    invoke-static {v3}, Lthreadsmod/autoblock/AutoBlockSync;->viewerId(Ljava/lang/Object;)Ljava/lang/String;

    move-result-object v3

    invoke-virtual {v0, v3}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v3

    if-nez v3, :viewer_session_current

    goto :release_return

    :viewer_session_current
    invoke-virtual {p3, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :context_changed

    if-eq p1, p2, :context_current

    goto :context_changed

    :context_current
    invoke-static {p1, p3}, Lthreadsmod/autoblock/ModStateStore;->nextQueued(Landroid/content/Context;Ljava/lang/String;)Lthreadsmod/autoblock/ModStateStore$QueueItem;

    move-result-object p2

    if-eqz p2, :check_automatic_drain

    const/4 p0, 0x1

    :check_automatic_drain
    if-nez p0, :requested_drain

    if-eqz p6, :release_return

    invoke-static {p1}, Lthreadsmod/autoblock/AutoBlockSync;->isEnabled(Landroid/content/Context;)Z

    move-result p0

    if-eqz p0, :release_return

    :requested_drain
    invoke-static {p4, p5}, Lthreadsmod/autoblock/AutoBlockSync;->scheduleManualDrain(J)V

    return-void

    :context_changed
    invoke-static {v1, v2}, Lthreadsmod/autoblock/AutoBlockSync;->scheduleManualDrain(J)V

    return-void

    :release_return
    return-void

    :stale_owner
    :try_stale_release_start
    monitor-exit v0

    return-void

    :catch_release
    move-exception p0

    monitor-exit v0
    :try_stale_release_end
    .catchall {:try_stale_release_start .. :try_stale_release_end} :catch_release

    throw p0
.end method

.method public static synthetic access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V
    .locals 0

    invoke-static/range {p0 .. p6}, Lthreadsmod/autoblock/AutoBlockSync;->releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V

    return-void
.end method

.method public static quarantineCompletionReview(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z
    .locals 1

    invoke-static {p1, p2}, Lthreadsmod/autoblock/AutoBlockSync;->installLocalCompletionReview(Ljava/lang/String;Ljava/lang/String;)V

    nop

    :try_quarantine_start
    invoke-static {p0, p1, p2}, Lthreadsmod/autoblock/ModStateStore;->quarantineCompletionReview(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z

    move-result p0
    :try_quarantine_end
    .catchall {:try_quarantine_start .. :try_quarantine_end} :catch_quarantine

    goto :quarantine_join

    :catch_quarantine
    move-exception p0

    const/4 p0, 0x0

    :quarantine_join
    if-eqz p0, :quarantine_return

    new-instance v0, Ljava/util/HashSet;

    invoke-direct {v0}, Ljava/util/HashSet;-><init>()V

    invoke-virtual {v0, p2}, Ljava/util/HashSet;->add(Ljava/lang/Object;)Z

    invoke-static {p1, v0}, Lthreadsmod/autoblock/AutoBlockSync;->clearLocalCompletionReviewAfterRetry(Ljava/lang/String;Ljava/util/Set;)V

    :quarantine_return
    return p0
.end method

.method private static drainManualQueue()V
    .locals 0

    return-void
.end method

.method private static loadTargets(Landroid/content/Context;Ljava/lang/String;Z)Ljava/util/List;
    .locals 1

    const/4 v0, 0x0

    return-object v0
.end method

.method private static scheduleManualDrain(J)V
    .locals 5

    sget-object v0, Lthreadsmod/autoblock/AutoBlockSync;->MAIN:Landroid/os/Handler;

    new-instance v1, Lthreadsmod/autoblock/AutoBlockSync$ManualDrainRunnable;

    invoke-direct {v1}, Lthreadsmod/autoblock/AutoBlockSync$ManualDrainRunnable;-><init>()V

    const-wide/16 v2, 0x0

    invoke-static {v2, v3, p0, p1}, Ljava/lang/Math;->max(JJ)J

    move-result-wide p0

    invoke-virtual {v0, v1, p0, p1}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    move-result v0

    if-nez v0, :accepted

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->getForegroundActivity()Landroid/app/Activity;

    move-result-object v0

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->getCurrentViewer()Ljava/lang/String;

    move-result-object v1

    if-eqz v0, :accepted

    invoke-static {v1}, Lthreadsmod/autoblock/AutoBlockSync;->isDecimalId(Ljava/lang/String;)Z

    move-result v2

    if-eqz v2, :accepted

    invoke-virtual {v1}, Ljava/lang/String;->length()I

    move-result v2

    const/16 v3, 0x18

    if-gt v2, v3, :accepted

    :try_refusal_start
    const-string v2, "Scheduler wake was rejected; reopen Threads to resume queued work."

    invoke-static {v0, v1, v2}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    const-string v2, "scheduler_wake_rejected"

    const-string v3, "Queued work is paused until Threads resumes in the foreground."

    const/4 v4, 0x1

    invoke-static {v0, v1, v2, v3, v4}, Lthreadsmod/autoblock/ModStateStore;->recordRuntimeState(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Z)V
    :try_refusal_end
    .catchall {:try_refusal_start .. :try_refusal_end} :catch_refusal

    goto :accepted

    :catch_refusal
    move-exception v0

    :accepted
    return-void
.end method
