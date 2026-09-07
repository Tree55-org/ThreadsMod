.class final Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;
.super Ljava/lang/Object;
.source "AutoBlockSync.java"


# instance fields
.field private final activityRef:Ljava/lang/ref/WeakReference;

.field private final forceRefresh:Z

.field private final schedulerToken:J

.field private final userSession:Ljava/lang/Object;

.field private final viewer:Ljava/lang/String;


# direct methods
.method static synthetic access$forceRefresh(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;)Z
    .locals 1

    iget-boolean v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->forceRefresh:Z

    return v0
.end method

.method static synthetic access$schedulerToken(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;)J
    .locals 2

    iget-wide v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->schedulerToken:J

    return-wide v0
.end method

.method static synthetic access$userSession(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;)Ljava/lang/Object;
    .locals 1

    iget-object v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->userSession:Ljava/lang/Object;

    return-object v0
.end method

.method static synthetic access$viewer(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;)Ljava/lang/String;
    .locals 1

    iget-object v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->viewer:Ljava/lang/String;

    return-object v0
.end method


# virtual methods
.method public run()V
    .locals 9

    :try_outer_start
    iget-object v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->activityRef:Ljava/lang/ref/WeakReference;

    invoke-virtual {v0}, Ljava/lang/ref/WeakReference;->get()Ljava/lang/Object;

    move-result-object v0

    move-object v3, v0

    check-cast v3, Landroid/app/Activity;

    if-nez v3, :activity_present

    iget-boolean v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->forceRefresh:Z

    if-eqz v0, :null_force_refresh_done

    iget-object v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->viewer:Ljava/lang/String;

    invoke-static {v0}, Lthreadsmod/autoblock/AutoBlockSync;->requestForceRefresh(Ljava/lang/String;)Z

    :null_force_refresh_done
    iget-wide v1, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->schedulerToken:J

    const/4 v3, 0x0

    iget-object v4, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->viewer:Ljava/lang/String;

    const-wide/16 v5, 0x0

    const/4 v7, 0x1

    invoke-static/range {v1 .. v7}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V

    return-void

    :activity_present
    iget-object v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->viewer:Ljava/lang/String;

    iget-boolean v1, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->forceRefresh:Z

    invoke-static {v3, v0, v1}, Lthreadsmod/autoblock/AutoBlockSync;->loadTargets(Landroid/content/Context;Ljava/lang/String;Z)Ljava/util/List;

    move-result-object v0

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->access$main()Landroid/os/Handler;

    move-result-object v1

    new-instance v2, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;

    invoke-direct {v2, p0, v0, v3}, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;-><init>(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;Ljava/util/List;Landroid/app/Activity;)V

    invoke-virtual {v1, v2}, Landroid/os/Handler;->post(Ljava/lang/Runnable;)Z

    move-result v0

    if-nez v0, :accepted

    iget-boolean v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->forceRefresh:Z

    if-eqz v0, :force_refresh_done

    iget-object v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->viewer:Ljava/lang/String;

    invoke-static {v0}, Lthreadsmod/autoblock/AutoBlockSync;->requestForceRefresh(Ljava/lang/String;)Z

    :force_refresh_done
    iget-object v4, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->viewer:Ljava/lang/String;

    const-string v0, "Sync could not return to the Threads screen; reopen Threads to resume safely."

    invoke-static {v3, v4, v0}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    iget-wide v1, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->schedulerToken:J

    const-wide/16 v5, 0x0

    const/4 v7, 0x1

    invoke-static/range {v1 .. v7}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V
    :try_outer_end
    .catchall {:try_outer_start .. :try_outer_end} :catch_outer

    :accepted
    goto :done

    :catch_outer
    move-exception v0

    iget-object v1, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->activityRef:Ljava/lang/ref/WeakReference;

    invoke-virtual {v1}, Ljava/lang/ref/WeakReference;->get()Ljava/lang/Object;

    move-result-object v1

    check-cast v1, Landroid/app/Activity;

    if-eqz v1, :catch_activity_fallback

    goto :catch_activity_join

    :catch_activity_fallback

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->getForegroundActivity()Landroid/app/Activity;

    move-result-object v1

    :catch_activity_join
    move-object v4, v1


    iget-wide v2, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->schedulerToken:J

    invoke-static {v2, v3}, Lthreadsmod/autoblock/AutoBlockSync;->isSchedulerOwner(J)Z

    move-result v1

    if-nez v1, :catch_owner_current

    return-void

    :catch_owner_current
    iget-boolean v1, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->forceRefresh:Z

    if-eqz v1, :catch_force_refresh_done

    iget-object v1, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->viewer:Ljava/lang/String;

    invoke-static {v1}, Lthreadsmod/autoblock/AutoBlockSync;->requestForceRefresh(Ljava/lang/String;)Z

    :catch_force_refresh_done
    if-eqz v4, :catch_status_done

    iget-object v5, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->viewer:Ljava/lang/String;

    invoke-static {v4, v5}, Lthreadsmod/autoblock/AutoBlockSync;->persistRetryDeadline(Landroid/content/Context;Ljava/lang/String;)Z

    const-string v6, "Passive matching stopped at a bounded local failure; retry is paused."

    invoke-static {v4, v5, v6}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    :catch_status_done

    const-string v1, "ThreadsModAutoBlock"

    const-string v6, "Passive matching stopped at a bounded local failure."

    invoke-static {v1, v6}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    iget-wide v2, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->schedulerToken:J

    iget-object v5, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->viewer:Ljava/lang/String;

    const-wide/32 v6, 0x1d8a8

    const/4 v8, 0x1

    invoke-static/range {v2 .. v8}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V

    :done
    return-void
.end method
