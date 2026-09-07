.class final Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;
.super Ljava/lang/Object;
.source "BridgeCallbackDispatcher.java"

# interfaces
.implements Ljava/lang/Runnable;


# annotations
.annotation system Ldalvik/annotation/EnclosingClass;
    value = Lthreadsmod/autoblock/BridgeCallbackDispatcher;
.end annotation

.annotation system Ldalvik/annotation/InnerClass;
    accessFlags = 0x1a
    name = "Delivery"
.end annotation


# instance fields
.field private final callback:Lthreadsmod/autoblock/BridgeCallback;

.field private final kind:I

.field private final stage:Ljava/lang/String;

.field private final targetId:Ljava/lang/String;


# direct methods
.method constructor <init>(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;I)V
    .locals 0

    .line 53
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    .line 54
    iput-object p1, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->callback:Lthreadsmod/autoblock/BridgeCallback;

    .line 55
    iput-object p2, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->targetId:Ljava/lang/String;

    .line 56
    iput-object p3, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->stage:Ljava/lang/String;

    .line 57
    iput p4, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->kind:I

    .line 58
    return-void
.end method


# virtual methods
.method public run()V
    .locals 3

    .line 62
    iget v0, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->kind:I

    const/4 v1, 0x1

    if-ne v0, v1, :cond_0

    .line 63
    iget-object v0, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->callback:Lthreadsmod/autoblock/BridgeCallback;

    iget-object v1, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->targetId:Ljava/lang/String;

    invoke-interface {v0, v1}, Lthreadsmod/autoblock/BridgeCallback;->onBridgeStarted(Ljava/lang/String;)V

    goto :goto_0

    .line 64
    :cond_0
    iget v0, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->kind:I

    const/4 v1, 0x2

    if-ne v0, v1, :cond_1

    .line 65
    iget-object v0, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->callback:Lthreadsmod/autoblock/BridgeCallback;

    iget-object v1, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->targetId:Ljava/lang/String;

    iget-object v2, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->stage:Ljava/lang/String;

    invoke-interface {v0, v1, v2}, Lthreadsmod/autoblock/BridgeCallback;->onBridgeFailure(Ljava/lang/String;Ljava/lang/String;)V

    goto :goto_0

    .line 66
    :cond_1
    iget v0, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->kind:I

    const/4 v1, 0x3

    if-ne v0, v1, :cond_2

    .line 67
    iget-object v0, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->callback:Lthreadsmod/autoblock/BridgeCallback;

    iget-object v1, p0, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;->targetId:Ljava/lang/String;

    invoke-interface {v0, v1}, Lthreadsmod/autoblock/BridgeCallback;->onBridgeSuccess(Ljava/lang/String;)V

    .line 69
    :cond_2
    :goto_0
    return-void
.end method

