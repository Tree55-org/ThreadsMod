    invoke-direct/range {v27 .. v41}, LX/03gT;-><init>(LX/09jq;LX/09jq;LX/00xF;LX/03hL;Ljava/lang/String;FFZZZZZZZ)V

    move-object/from16 v2, v27

    iget-object v1, v0, LX/03gS;->A04:Lcom/instagram/common/session/UserSession;

    invoke-static {v8, v1}, LX/03gS;->threadsmodResolveAuthorSnapshot(LX/00LX;Lcom/instagram/common/session/UserSession;)Lthreadsmod/inlinecontrol/InlineBlockRequest;

    move-result-object v1

    iput-object v1, v2, LX/03gT;->threadsmodRequest:Lthreadsmod/inlinecontrol/InlineBlockRequest;

    if-eqz v1, :threadsmod_snapshot_bound

    invoke-virtual {v1}, Lthreadsmod/inlinecontrol/InlineBlockRequest;->getMediaKey()Ljava/lang/String;

    move-result-object v1

    iput-object v1, v2, LX/03gT;->threadsmodMediaId:Ljava/lang/String;

    :threadsmod_snapshot_bound
    iget-object v1, v6, LX/01cE;->A0C:Ljava/lang/Integer;

    move-object/from16 v73, v1
