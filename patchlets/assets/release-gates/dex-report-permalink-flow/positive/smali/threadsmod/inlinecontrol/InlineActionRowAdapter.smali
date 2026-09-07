.class public final Lthreadsmod/inlinecontrol/InlineActionRowAdapter;
.super Ljava/lang/Object;

.method public static render(LX/09jq;LX/09dm;LX/03gT;Lthreadsmod/inlinecontrol/InlineBlockRequest;JJ)V
    .locals 22

    sget-object v2, LX/08ub;->A00:LX/08yw;
    const/4 v4, 0x0
    invoke-static {v2, v4}, LX/0Ca6;->A00(LX/08ub;Lkotlin/jvm/functions/Function1;)LX/08ub;
    move-result-object v2
    const-string v4, "threadsmod_inline_block"
    invoke-static {v2, v4}, LX/0DaO;->A00(LX/08ub;Ljava/lang/String;)LX/08ub;
    move-result-object v2

    const/4 v4, 0x0
    if-eqz v4, :animation_ready
    const/4 v5, 0x0
    const/4 v6, 0x0
    invoke-static {v2, v5, v6}, LX/09qr;->A02(LX/08ub;Lkotlin/jvm/functions/Function1;Lkotlin/jvm/functions/Function3;)LX/08ub;
    move-result-object v2

    :animation_ready
    move-object/from16 v0, p0
    move-object/from16 v1, p1
    const-string v3, "Block user"
    const/4 v4, 0x0
    const/4 v5, 0x0
    const/4 v6, 0x0
    const/4 v7, 0x0
    const/4 v8, 0x0
    const/4 v9, 0x0
    const/4 v10, 0x0
    const/4 v11, 0x0
    const v12, 0xf700
    const-wide/16 v13, 0x0
    const-wide/16 v15, 0x0
    const/16 v17, 0x1
    const/16 v18, 0x0
    const/16 v19, 0x1
    const/16 v20, 0x0
    const/16 v21, 0x0
    invoke-static/range {v0 .. v21}, LX/03hH;->A00(LX/09jq;LX/09dm;LX/08ub;Ljava/lang/String;Ljava/lang/String;Lkotlin/jvm/functions/Function0;Lkotlin/jvm/functions/Function0;FIIIIIJJZZZZZ)V

    return-void
.end method
