.class public final Lthreadsmod/reporting/ReportPayload;
.super Ljava/lang/Object;

.field private final request:Lthreadsmod/reporting/ReportRequest;

.method public constructor <init>(Lthreadsmod/reporting/ReportRequest;)V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lthreadsmod/reporting/ReportPayload;->request:Lthreadsmod/reporting/ReportRequest;
    return-void
.end method

.method private isValid()Z
    .locals 1

    const/4 v0, 0x1
    return v0
.end method

.method toJson()Lorg/json/JSONObject;
    .locals 7

    new-instance v0, Lorg/json/JSONObject;
    invoke-direct {v0}, Lorg/json/JSONObject;-><init>()V
    invoke-direct {p0}, Lthreadsmod/reporting/ReportPayload;->isValid()Z
    move-result v1
    if-nez v1, :payload_valid
    return-object v0

    :payload_valid
    :try_start
    iget-object v1, p0, Lthreadsmod/reporting/ReportPayload;->request:Lthreadsmod/reporting/ReportRequest;
    invoke-virtual {v1}, Lthreadsmod/reporting/ReportRequest;->getPermalink()Ljava/lang/String;
    move-result-object v2
    const-string v3, "targetUrl"
    invoke-virtual {v0, v3, v2}, Lorg/json/JSONObject;->put(Ljava/lang/String;Ljava/lang/Object;)Lorg/json/JSONObject;
    new-instance v4, Lorg/json/JSONArray;
    invoke-direct {v4}, Lorg/json/JSONArray;-><init>()V
    iget-object v1, p0, Lthreadsmod/reporting/ReportPayload;->request:Lthreadsmod/reporting/ReportRequest;
    invoke-virtual {v1}, Lthreadsmod/reporting/ReportRequest;->getPermalink()Ljava/lang/String;
    move-result-object v5
    invoke-virtual {v5}, Ljava/lang/String;->length()I
    move-result v6
    if-eqz v6, :evidence_ready
    iget-object v1, p0, Lthreadsmod/reporting/ReportPayload;->request:Lthreadsmod/reporting/ReportRequest;
    invoke-virtual {v1}, Lthreadsmod/reporting/ReportRequest;->getPermalink()Ljava/lang/String;
    move-result-object v5
    invoke-virtual {v4, v5}, Lorg/json/JSONArray;->put(Ljava/lang/Object;)Lorg/json/JSONArray;

    :evidence_ready
    const-string v3, "evidence"
    invoke-virtual {v0, v3, v4}, Lorg/json/JSONObject;->put(Ljava/lang/String;Ljava/lang/Object;)Lorg/json/JSONObject;
    :try_end
    .catch Ljava/lang/Throwable; {:try_start .. :try_end} :catch
    return-object v0

    :catch
    move-exception v1
    new-instance v0, Lorg/json/JSONObject;
    invoke-direct {v0}, Lorg/json/JSONObject;-><init>()V
    return-object v0
.end method
