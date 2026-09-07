.class public final Lthreadsmod/reporting/ReportClient;
.super Ljava/lang/Object;

.method public static queueExplicit(Landroid/content/Context;Ljava/lang/String;Lthreadsmod/reporting/ReportRequest;Ljava/lang/String;Lthreadsmod/reporting/ReportResultCallback;)V
    .locals 2

    invoke-virtual {p2}, Lthreadsmod/reporting/ReportRequest;->isValidForNewQueue()Z
    move-result v0
    if-eqz v0, :invalid
    new-instance v1, Ljava/lang/Thread;
    invoke-direct {v1}, Ljava/lang/Thread;-><init>()V
    invoke-virtual {v1}, Ljava/lang/Thread;->start()V

    :invalid
    return-void
.end method
