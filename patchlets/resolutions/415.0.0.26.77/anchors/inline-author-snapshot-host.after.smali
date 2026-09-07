    const-wide v0, 0x81133600016840L

    check-cast v2, Lcom/facebook/mobileconfig/factory/MobileConfigUnsafeContext;

    invoke-interface {v2, v0, v1}, Lcom/facebook/mobileconfig/factory/MobileConfigUnsafeContext;->Axm(J)Z

    move-result v0

    return v0

    :cond_0
    return v3

    # threadsmod exact-SHA inline author snapshot owner
.end method

.method private static threadsmodResolveAuthorSnapshot(LX/0rU;Lcom/instagram/common/session/UserSession;)Lthreadsmod/inlinecontrol/InlineBlockRequest;
    .locals 6

    :try_start_threadsmod_snapshot
    if-eqz p0, :threadsmod_snapshot_null

    if-eqz p1, :threadsmod_snapshot_null

    iget-object v0, p0, LX/0rU;->threadsmodMediaId:Ljava/lang/String;

    if-eqz v0, :threadsmod_snapshot_null

    invoke-static {p1, v0}, LX/023;->A0e(Lcom/instagram/common/session/UserSession;Ljava/lang/String;)LX/6wn;

    move-result-object v1

    if-eqz v1, :threadsmod_snapshot_null

    invoke-static {v1}, LX/021;->A0z(LX/6wn;)LX/2fp;

    move-result-object v2

    if-eqz v2, :threadsmod_snapshot_null

    invoke-virtual {v2}, LX/2fp;->getId()Ljava/lang/String;

    move-result-object v3

    if-eqz v3, :threadsmod_snapshot_null

    invoke-static {v2}, LX/021;->A1B(LX/2fp;)Ljava/lang/String;

    move-result-object v4

    invoke-static {v0, v3, v4, v2, v1}, Lthreadsmod/inlinecontrol/InlineBlockRequest;->createHostBound(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/Object;Ljava/lang/Object;)Lthreadsmod/inlinecontrol/InlineBlockRequest;

    move-result-object v5
    :try_end_threadsmod_snapshot
    .catch Ljava/lang/Throwable; {:try_start_threadsmod_snapshot .. :try_end_threadsmod_snapshot} :threadsmod_snapshot_catch

    return-object v5

    :threadsmod_snapshot_catch
    move-exception v0

    :threadsmod_snapshot_null
    const/4 v0, 0x0

    return-object v0
.end method
