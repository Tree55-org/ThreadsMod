    :goto_1f
    move/from16 v0, v35

    invoke-static {v11, v0}, LX/8qi;->A0H(LX/8qi;Z)V

    move/from16 v0, v31

    invoke-static {v11, v0}, LX/8qi;->A0H(LX/8qi;Z)V

    move-object/from16 v84, v1

    move-object/from16 v85, p3

    move-object/from16 v86, v41

    invoke-static/range {v85 .. v86}, LX/0sC;->threadsmodResolveAuthorSnapshot(LX/0rU;Lcom/instagram/common/session/UserSession;)Lthreadsmod/inlinecontrol/InlineBlockRequest;

    move-result-object v86

    move-wide/from16 v87, v104

    move-wide/from16 v89, v102

    invoke-static/range {v83 .. v90}, Lthreadsmod/inlinecontrol/InlineActionRowAdapter;->render(LX/8xf;LX/8qj;LX/0rU;Lthreadsmod/inlinecontrol/InlineBlockRequest;JJ)V

    if-eqz p40, :cond_57
