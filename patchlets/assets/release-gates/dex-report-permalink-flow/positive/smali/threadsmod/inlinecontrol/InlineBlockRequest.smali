.class public final Lthreadsmod/inlinecontrol/InlineBlockRequest;
.super Ljava/lang/Object;

.field public final media:LX/6wn;

.method public constructor <init>(LX/6wn;)V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lthreadsmod/inlinecontrol/InlineBlockRequest;->media:LX/6wn;
    return-void
.end method

.method public getResolvedMediaModel()Ljava/lang/Object;
    .locals 1

    iget-object v0, p0, Lthreadsmod/inlinecontrol/InlineBlockRequest;->media:LX/6wn;
    return-object v0
.end method

.method public getLabel()Ljava/lang/String;
    .locals 1

    const-string v0, "profile"
    return-object v0
.end method
