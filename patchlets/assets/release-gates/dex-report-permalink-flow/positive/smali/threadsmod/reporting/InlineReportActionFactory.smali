.class public final Lthreadsmod/reporting/InlineReportActionFactory;
.super Ljava/lang/Object;

.method public static createRequest(Lthreadsmod/inlinecontrol/InlineBlockRequest;)Lthreadsmod/reporting/ReportRequest;
    .locals 12

    :try_start
    invoke-virtual {p0}, Lthreadsmod/inlinecontrol/InlineBlockRequest;->getResolvedMediaModel()Ljava/lang/Object;
    move-result-object v0
    check-cast v0, {{mediaDescriptor}}
{{mediaReceiverSetup}}
    invoke-virtual {p0}, Lthreadsmod/inlinecontrol/InlineBlockRequest;->getLabel()Ljava/lang/String;
    move-result-object v11
    {{mediaInvokeOpcode}} {v0}, {{mediaCodeMethod}}
    move-result-object v10
    const-string v1, ""
    invoke-static {v11, v1, v10}, Lthreadsmod/reporting/ReportRequest;->resolveHostPermalink(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
    move-result-object v1
    invoke-virtual {v1}, Ljava/lang/String;->length()I
    move-result v8
    if-nez v8, :permalink_ready
    {{mediaInvokeOpcode}} {v0}, {{mediaPermalinkMethod}}
    move-result-object v8
    const-string v10, ""
    invoke-static {v11, v8, v10}, Lthreadsmod/reporting/ReportRequest;->resolveHostPermalink(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
    move-result-object v1

    :permalink_ready
    {{mediaInvokeOpcode}} {v0}, {{mediaCaptionMethod}}
    move-result-object v9
    const-string v6, ""
    if-eqz v9, :excerpt_ready
    invoke-interface {v9}, {{captionTextMethod}}
    move-result-object v6
    if-nez v6, :excerpt_ready
    const-string v6, ""

    :excerpt_ready
    invoke-static {v6}, Lthreadsmod/reporting/ReportRequest;->resolveHostExcerpt(Ljava/lang/String;)Ljava/lang/String;
    move-result-object v6
    new-instance v2, Lthreadsmod/reporting/ReportRequest;
    const-string v3, "item"
    move-object v4, v11
    const-string v5, "1234"
    const-string v7, ""
    move-object v8, v1
    invoke-direct/range {v2 .. v8}, Lthreadsmod/reporting/ReportRequest;-><init>(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V
    invoke-virtual {v2}, Lthreadsmod/reporting/ReportRequest;->getPermalink()Ljava/lang/String;
    move-result-object v0
    invoke-virtual {v0}, Ljava/lang/String;->length()I
    move-result v0
    if-eqz v0, :invalid
    :try_end
    .catch Ljava/lang/Throwable; {:try_start .. :try_end} :catch
    return-object v2

    :invalid
    const/4 v2, 0x0
    return-object v2

    :catch
    move-exception v9
    const/4 v2, 0x0
    return-object v2
.end method
