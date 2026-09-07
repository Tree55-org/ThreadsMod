.class public final Lfixture/AutomaticCaller$PrePaceRunnable;
.super Ljava/lang/Object;
.source "AutomaticCaller.java"

.implements Ljava/lang/Runnable;


# instance fields
.field private final this$0:Lfixture/AutomaticCaller;

.field private final val$paceToken:I


# direct methods
.method public constructor <init>(Lfixture/AutomaticCaller;I)V
    .locals 0

    iput-object p1, p0, Lfixture/AutomaticCaller$PrePaceRunnable;->this$0:Lfixture/AutomaticCaller;

    iput p2, p0, Lfixture/AutomaticCaller$PrePaceRunnable;->val$paceToken:I

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method


# virtual methods
.method public run()V
    .locals 2

    iget-object v0, p0, Lfixture/AutomaticCaller$PrePaceRunnable;->this$0:Lfixture/AutomaticCaller;

    invoke-static {v0}, Lfixture/AutomaticCaller;->access$finished(Lfixture/AutomaticCaller;)Ljava/util/concurrent/atomic/AtomicBoolean;

    move-result-object v0

    invoke-virtual {v0}, Ljava/util/concurrent/atomic/AtomicBoolean;->get()Z

    move-result v0

    if-nez v0, :done

    iget-object v0, p0, Lfixture/AutomaticCaller$PrePaceRunnable;->this$0:Lfixture/AutomaticCaller;

    invoke-static {v0}, Lfixture/AutomaticCaller;->access$waiting(Lfixture/AutomaticCaller;)Z

    move-result v0

    if-nez v0, :done

    iget-object v0, p0, Lfixture/AutomaticCaller$PrePaceRunnable;->this$0:Lfixture/AutomaticCaller;

    invoke-static {v0}, Lfixture/AutomaticCaller;->access$token(Lfixture/AutomaticCaller;)I

    move-result v0

    iget v1, p0, Lfixture/AutomaticCaller$PrePaceRunnable;->val$paceToken:I

    if-ne v0, v1, :done

    iget-object v0, p0, Lfixture/AutomaticCaller$PrePaceRunnable;->this$0:Lfixture/AutomaticCaller;

    invoke-static {v0}, Lfixture/AutomaticCaller;->access$next(Lfixture/AutomaticCaller;)V

    :done
    return-void
.end method
