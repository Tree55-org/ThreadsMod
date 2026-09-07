.class public final Lthreadsmod/reporting/ReportRequest;
.super Ljava/lang/Object;

.field private final profileUsername:Ljava/lang/String;
.field private final permalink:Ljava/lang/String;

.method public static resolveHostPermalink(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
    .locals 0

    return-object p1
.end method

.method public static resolveHostExcerpt(Ljava/lang/String;)Ljava/lang/String;
    .locals 0

    return-object p0
.end method

.method public constructor <init>(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V
    .locals 2

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p2, p0, Lthreadsmod/reporting/ReportRequest;->profileUsername:Ljava/lang/String;
    iget-object v1, p0, Lthreadsmod/reporting/ReportRequest;->profileUsername:Ljava/lang/String;
    invoke-static {p6, v1}, Lthreadsmod/reporting/ReportValues;->httpsThreadsPermalink(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
    move-result-object v0
    iput-object v0, p0, Lthreadsmod/reporting/ReportRequest;->permalink:Ljava/lang/String;
    return-void
.end method

.method public getPermalink()Ljava/lang/String;
    .locals 1

    iget-object v0, p0, Lthreadsmod/reporting/ReportRequest;->permalink:Ljava/lang/String;
    return-object v0
.end method

.method public isValid()Z
    .locals 1

    const/4 v0, 0x1
    return v0
.end method

.method public isValidForNewQueue()Z
    .locals 1

    invoke-virtual {p0}, Lthreadsmod/reporting/ReportRequest;->isValid()Z
    move-result v0
    if-eqz v0, :invalid
    iget-object v0, p0, Lthreadsmod/reporting/ReportRequest;->permalink:Ljava/lang/String;
    invoke-virtual {v0}, Ljava/lang/String;->length()I
    move-result v0
    if-lez v0, :invalid
    const/4 v0, 0x1
    goto :result

    :invalid
    const/4 v0, 0x0

    :result
    return v0
.end method
