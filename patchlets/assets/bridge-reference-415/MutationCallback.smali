.class public final Lthreadsmod/autoblock/MutationCallback;
.super Ljava/lang/Object;
.source "MutationCallback.smali"

# interfaces
.implements LX/Mwt;


# instance fields
.field private A00:Z
.field private final A01:Lthreadsmod/autoblock/BridgeCallback;
.field private final A02:Ljava/lang/String;


# direct methods
.method public constructor <init>(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;)V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lthreadsmod/autoblock/MutationCallback;->A01:Lthreadsmod/autoblock/BridgeCallback;
    iput-object p2, p0, Lthreadsmod/autoblock/MutationCallback;->A02:Ljava/lang/String;

    return-void
.end method

.method private final declared-synchronized A00(Ljava/lang/String;)V
    .locals 2

    iget-boolean v0, p0, Lthreadsmod/autoblock/MutationCallback;->A00:Z
    if-nez v0, :return_0

    const/4 v0, 0x1
    iput-boolean v0, p0, Lthreadsmod/autoblock/MutationCallback;->A00:Z

    iget-object v0, p0, Lthreadsmod/autoblock/MutationCallback;->A01:Lthreadsmod/autoblock/BridgeCallback;
    iget-object v1, p0, Lthreadsmod/autoblock/MutationCallback;->A02:Ljava/lang/String;
    invoke-static {v0, v1, p1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V

    :return_0
    return-void
.end method


# virtual methods
.method public final DFF()V
    .locals 2

    iget-object v0, p0, Lthreadsmod/autoblock/MutationCallback;->A01:Lthreadsmod/autoblock/BridgeCallback;
    iget-object v1, p0, Lthreadsmod/autoblock/MutationCallback;->A02:Ljava/lang/String;
    invoke-static {v0, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->started(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;)V

    return-void
.end method

.method public final DKv()V
    .locals 1

    const-string v0, "mutation_failure"
    invoke-direct {p0, v0}, Lthreadsmod/autoblock/MutationCallback;->A00(Ljava/lang/String;)V

    return-void
.end method

.method public final Dg7()V
    .locals 1

    const-string v0, "mutation_ended"
    invoke-direct {p0, v0}, Lthreadsmod/autoblock/MutationCallback;->A00(Ljava/lang/String;)V

    return-void
.end method

.method public final onCancel()V
    .locals 1

    const-string v0, "mutation_cancelled"
    invoke-direct {p0, v0}, Lthreadsmod/autoblock/MutationCallback;->A00(Ljava/lang/String;)V

    return-void
.end method

.method public final declared-synchronized onSuccess()V
    .locals 2

    iget-boolean v0, p0, Lthreadsmod/autoblock/MutationCallback;->A00:Z
    if-nez v0, :return_0

    const/4 v0, 0x1
    iput-boolean v0, p0, Lthreadsmod/autoblock/MutationCallback;->A00:Z

    iget-object v0, p0, Lthreadsmod/autoblock/MutationCallback;->A01:Lthreadsmod/autoblock/BridgeCallback;
    iget-object v1, p0, Lthreadsmod/autoblock/MutationCallback;->A02:Ljava/lang/String;
    invoke-static {v0, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->success(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;)V

    :return_0
    return-void
.end method
