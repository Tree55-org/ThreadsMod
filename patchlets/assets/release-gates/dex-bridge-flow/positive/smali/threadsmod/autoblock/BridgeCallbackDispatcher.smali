.class public final Lthreadsmod/autoblock/BridgeCallbackDispatcher;
.super Ljava/lang/Object;
.source "BridgeCallbackDispatcher.java"


# annotations
.annotation system Ldalvik/annotation/MemberClasses;
    value = {
        Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;
    }
.end annotation


# static fields
.field private static final FAILURE:I = 0x2

.field private static final MAIN:Landroid/os/Handler;

.field private static final STARTED:I = 0x1

.field private static final SUCCESS:I = 0x3


# direct methods
.method static constructor <clinit>()V
    .locals 2

    .line 18
    new-instance v0, Landroid/os/Handler;

    invoke-static {}, Landroid/os/Looper;->getMainLooper()Landroid/os/Looper;

    move-result-object v1

    invoke-direct {v0, v1}, Landroid/os/Handler;-><init>(Landroid/os/Looper;)V

    sput-object v0, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->MAIN:Landroid/os/Handler;

    return-void
.end method

.method private constructor <init>()V
    .locals 0

    .line 20
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method private static enqueue(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;I)V
    .locals 2

    .line 39
    if-eqz p0, :cond_2

    if-eqz p1, :cond_2

    const/4 v0, 0x2

    if-ne p3, v0, :cond_0

    if-eqz p2, :cond_2

    .line 42
    :cond_0
    sget-object v0, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->MAIN:Landroid/os/Handler;

    new-instance v1, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;

    invoke-direct {v1, p0, p1, p2, p3}, Lthreadsmod/autoblock/BridgeCallbackDispatcher$Delivery;-><init>(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;I)V

    invoke-virtual {v0, v1}, Landroid/os/Handler;->post(Ljava/lang/Runnable;)Z

    move-result p0

    if-eqz p0, :cond_1

    .line 45
    return-void

    .line 43
    :cond_1
    new-instance p0, Ljava/lang/IllegalStateException;

    invoke-direct {p0}, Ljava/lang/IllegalStateException;-><init>()V

    throw p0

    .line 40
    :cond_2
    new-instance p0, Ljava/lang/IllegalArgumentException;

    invoke-direct {p0}, Ljava/lang/IllegalArgumentException;-><init>()V

    throw p0
.end method

.method public static failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V
    .locals 1

    .line 27
    const/4 v0, 0x2

    invoke-static {p0, p1, p2, v0}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->enqueue(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;I)V

    .line 28
    return-void
.end method

.method public static started(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;)V
    .locals 2

    .line 23
    const/4 v0, 0x0

    const/4 v1, 0x1

    invoke-static {p0, p1, v0, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->enqueue(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;I)V

    .line 24
    return-void
.end method

.method public static success(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;)V
    .locals 2

    .line 31
    const/4 v0, 0x0

    const/4 v1, 0x3

    invoke-static {p0, p1, v0, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->enqueue(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;I)V

    .line 32
    return-void
.end method

