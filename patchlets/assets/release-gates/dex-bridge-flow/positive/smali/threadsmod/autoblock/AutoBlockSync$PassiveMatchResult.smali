.class final Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;
.super Ljava/lang/Object;
.source "AutoBlockSync.java"


# instance fields
.field final matched:Z

.field final storeValid:Z


# direct methods
.method constructor <init>(ZZ)V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-boolean p1, p0, Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;->storeValid:Z

    iput-boolean p2, p0, Lthreadsmod/autoblock/AutoBlockSync$PassiveMatchResult;->matched:Z

    return-void
.end method
