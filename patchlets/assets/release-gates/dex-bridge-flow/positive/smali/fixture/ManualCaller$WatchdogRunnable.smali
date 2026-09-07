.class final Lfixture/ManualCaller$WatchdogRunnable;
.super Ljava/lang/Object;

.implements Ljava/lang/Runnable;

.field private final this$0:Lfixture/ManualCaller;

.method constructor <init>(Lfixture/ManualCaller;)V
    .locals 0

    iput-object p1, p0, Lfixture/ManualCaller$WatchdogRunnable;->this$0:Lfixture/ManualCaller;

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method public final run()V
    .locals 1

    iget-object v0, p0, Lfixture/ManualCaller$WatchdogRunnable;->this$0:Lfixture/ManualCaller;

    invoke-static {v0}, Lfixture/ManualCaller;->access$abandon(Lfixture/ManualCaller;)V

    return-void
.end method
