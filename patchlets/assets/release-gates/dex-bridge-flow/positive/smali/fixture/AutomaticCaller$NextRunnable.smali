.class final Lfixture/AutomaticCaller$NextRunnable;
.super Ljava/lang/Object;
.source "AutomaticCaller.java"

.implements Ljava/lang/Runnable;


# instance fields
.field private final this$0:Lfixture/AutomaticCaller;


# direct methods
.method constructor <init>(Lfixture/AutomaticCaller;)V
    .locals 0

    iput-object p1, p0, Lfixture/AutomaticCaller$NextRunnable;->this$0:Lfixture/AutomaticCaller;

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method


# virtual methods
.method public final run()V
    .locals 1

    iget-object v0, p0, Lfixture/AutomaticCaller$NextRunnable;->this$0:Lfixture/AutomaticCaller;

    invoke-static {v0}, Lfixture/AutomaticCaller;->access$next(Lfixture/AutomaticCaller;)V

    return-void
.end method
