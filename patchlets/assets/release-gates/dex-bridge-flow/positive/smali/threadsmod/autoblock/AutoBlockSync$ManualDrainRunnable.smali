.class final Lthreadsmod/autoblock/AutoBlockSync$ManualDrainRunnable;
.super Ljava/lang/Object;
.source "AutoBlockSync.java"

.implements Ljava/lang/Runnable;


# direct methods
.method constructor <init>()V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method


# virtual methods
.method public run()V
    .locals 0

    invoke-static {}, Lthreadsmod/autoblock/AutoBlockSync;->drainManualQueue()V

    return-void
.end method
