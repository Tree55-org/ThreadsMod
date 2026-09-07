    :cond_30
    invoke-interface {v5}, LX/09dm;->EOv()V

    goto :goto_6

    # threadsmod exact-SHA immutable inline snapshot owner
.end method

.method private static threadsmodResolveAuthorSnapshot(LX/00LX;Lcom/instagram/common/session/UserSession;)Lthreadsmod/inlinecontrol/InlineBlockRequest;
    .locals 6

    :try_start_threadsmod_snapshot
    if-eqz p0, :threadsmod_snapshot_null

    if-eqz p1, :threadsmod_snapshot_null

    invoke-interface {p0}, LX/00LX;->CHe()Ljava/lang/String;

    move-result-object v0

    if-eqz v0, :threadsmod_snapshot_null

    invoke-static {p1, v0}, LX/0005;->A0T(Lcom/instagram/common/session/UserSession;Ljava/lang/String;)Lcom/instagram/feed/media/Media;

    move-result-object v1

    if-eqz v1, :threadsmod_snapshot_null

    invoke-virtual {v1}, Lcom/instagram/feed/media/Media;->A3N()Lcom/instagram/user/model/User;

    move-result-object v2

    if-eqz v2, :threadsmod_snapshot_null

    invoke-virtual {v2}, Lcom/instagram/user/model/User;->getId()Ljava/lang/String;

    move-result-object v3

    if-eqz v3, :threadsmod_snapshot_null

    invoke-virtual {v2}, Lcom/instagram/user/model/User;->A81()Ljava/lang/String;

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
