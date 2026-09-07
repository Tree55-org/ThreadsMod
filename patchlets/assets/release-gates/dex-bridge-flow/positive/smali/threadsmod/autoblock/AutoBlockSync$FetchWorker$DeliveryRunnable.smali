.class final Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;
.super Ljava/lang/Object;
.source "AutoBlockSync.java"

.implements Ljava/lang/Runnable;


# instance fields
.field private final this$0:Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;

.field private final val$activity:Landroid/app/Activity;

.field private final val$targets:Ljava/util/List;


# direct methods
.method constructor <init>(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;Ljava/util/List;Landroid/app/Activity;)V
    .locals 0

    iput-object p1, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->this$0:Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;

    iput-object p2, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->val$targets:Ljava/util/List;

    iput-object p3, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->val$activity:Landroid/app/Activity;

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method


# virtual methods
.method public run()V
    .locals 8

    iget-object v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->this$0:Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;

    invoke-static {v0}, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->access$schedulerToken(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;)J

    move-result-wide v0

    invoke-static {v0, v1}, Lthreadsmod/autoblock/AutoBlockSync;->isSchedulerOwner(J)Z

    move-result v0

    if-nez v0, :owner_current

    return-void

    :owner_current
    iget-object v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->val$targets:Ljava/util/List;

    invoke-interface {v0}, Ljava/util/List;->isEmpty()Z

    move-result v0

    if-eqz v0, :targets_present

    iget-object v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->val$activity:Landroid/app/Activity;

    iget-object v1, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->this$0:Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;

    invoke-static {v1}, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->access$viewer(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;)Ljava/lang/String;

    move-result-object v1

    const-string v2, "Verified list contains no Threads targets."

    invoke-static {v0, v1, v2}, Lthreadsmod/autoblock/AutoBlockSync;->setStatus(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    iget-object v0, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->this$0:Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;

    invoke-static {v0}, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->access$schedulerToken(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;)J

    move-result-wide v0

    iget-object v2, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->val$activity:Landroid/app/Activity;

    iget-object v3, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->this$0:Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;

    invoke-static {v3}, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->access$viewer(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;)Ljava/lang/String;

    move-result-object v3

    const-wide/16 v4, 0x0

    const/4 v6, 0x0

    invoke-static/range {v0 .. v6}, Lthreadsmod/autoblock/AutoBlockSync;->access$releaseSchedulerAndContinue(JLandroid/app/Activity;Ljava/lang/String;JZ)V

    return-void

    :targets_present
    new-instance v0, Lfixture/AutomaticCaller;

    iget-object v1, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->val$activity:Landroid/app/Activity;

    iget-object v2, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->this$0:Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;

    invoke-static {v2}, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->access$userSession(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;)Ljava/lang/Object;

    move-result-object v2

    iget-object v3, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->this$0:Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;

    invoke-static {v3}, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->access$viewer(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;)Ljava/lang/String;

    move-result-object v3

    iget-object v4, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->val$targets:Ljava/util/List;

    iget-object v5, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->this$0:Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;

    invoke-static {v5}, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->access$forceRefresh(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;)Z

    move-result v5

    iget-object v6, p0, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker$DeliveryRunnable;->this$0:Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;

    invoke-static {v6}, Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->access$schedulerToken(Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;)J

    move-result-wide v6

    invoke-direct/range {v0 .. v7}, Lfixture/AutomaticCaller;-><init>(Landroid/app/Activity;Ljava/lang/Object;Ljava/lang/String;Ljava/util/List;ZJ)V

    invoke-virtual {v0}, Lfixture/AutomaticCaller;->begin()V

    return-void
.end method
