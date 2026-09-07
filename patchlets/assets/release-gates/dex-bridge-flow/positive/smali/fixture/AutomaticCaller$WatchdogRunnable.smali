.class final Lfixture/AutomaticCaller$WatchdogRunnable;
.super Ljava/lang/Object;

.implements Ljava/lang/Runnable;

.field private final val$watchdogToken:I

.field private final this$0:Lfixture/AutomaticCaller;

.method constructor <init>(Lfixture/AutomaticCaller;I)V
    .locals 0

    iput-object p1, p0, Lfixture/AutomaticCaller$WatchdogRunnable;->this$0:Lfixture/AutomaticCaller;

    iput p2, p0, Lfixture/AutomaticCaller$WatchdogRunnable;->val$watchdogToken:I

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method public final run()V
    .locals 2

    iget-object v0, p0, Lfixture/AutomaticCaller$WatchdogRunnable;->this$0:Lfixture/AutomaticCaller;

    invoke-static {v0}, Lfixture/AutomaticCaller;->access$finished(Lfixture/AutomaticCaller;)Ljava/util/concurrent/atomic/AtomicBoolean;

    move-result-object v0

    invoke-virtual {v0}, Ljava/util/concurrent/atomic/AtomicBoolean;->get()Z

    move-result v0

    if-nez v0, :done

    iget-object v0, p0, Lfixture/AutomaticCaller$WatchdogRunnable;->this$0:Lfixture/AutomaticCaller;

    invoke-static {v0}, Lfixture/AutomaticCaller;->access$waiting(Lfixture/AutomaticCaller;)Z

    move-result v0

    if-eqz v0, :done

    iget-object v0, p0, Lfixture/AutomaticCaller$WatchdogRunnable;->this$0:Lfixture/AutomaticCaller;

    invoke-static {v0}, Lfixture/AutomaticCaller;->access$token(Lfixture/AutomaticCaller;)I

    move-result v0

    iget v1, p0, Lfixture/AutomaticCaller$WatchdogRunnable;->val$watchdogToken:I

    if-ne v0, v1, :done

    iget-object v0, p0, Lfixture/AutomaticCaller$WatchdogRunnable;->this$0:Lfixture/AutomaticCaller;

    invoke-static {v0}, Lfixture/AutomaticCaller;->access$currentId(Lfixture/AutomaticCaller;)Ljava/lang/String;

    move-result-object v1

    iget-object v0, p0, Lfixture/AutomaticCaller$WatchdogRunnable;->this$0:Lfixture/AutomaticCaller;

    invoke-static {v0, v1}, Lfixture/AutomaticCaller;->access$uncertain(Lfixture/AutomaticCaller;Ljava/lang/String;)V

    :done
    return-void
.end method
