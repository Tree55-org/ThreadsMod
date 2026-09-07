.class public final Lthreadsmod/reporting/ReportController;
.super Ljava/lang/Object;

.method public static queueFromForeground(Landroid/app/Activity;Ljava/lang/String;Lthreadsmod/reporting/ReportRequest;Ljava/lang/String;Lthreadsmod/reporting/ReportResultCallback;)V
    .locals 1

    invoke-virtual {p2}, Lthreadsmod/reporting/ReportRequest;->isValidForNewQueue()Z
    move-result v0
    if-eqz v0, :invalid
    invoke-static/range {p0 .. p4}, Lthreadsmod/reporting/ReportClient;->queueExplicit(Landroid/content/Context;Ljava/lang/String;Lthreadsmod/reporting/ReportRequest;Ljava/lang/String;Lthreadsmod/reporting/ReportResultCallback;)V

    :invalid
    return-void
.end method
