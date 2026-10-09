    :cond_c6
    move-object/from16 v1, p0

    iget-object v3, v1, LX/0Lbf;->A00:Landroid/app/Activity;

    iget-object v4, v1, LX/0Lbf;->A0B:Lcom/instagram/feed/media/Media;

    invoke-static {v0, v3, v4}, Lthreadsmod/video/VideoMenuAdapter;->render(LX/09dm;Landroid/app/Activity;Lcom/instagram/feed/media/Media;)V

    invoke-static {v5, v2}, Landroidx/compose/runtime/ComposerImpl;->A0O(Landroidx/compose/runtime/ComposerImpl;Z)V

    invoke-static {v5, v6}, Landroidx/compose/runtime/ComposerImpl;->A0O(Landroidx/compose/runtime/ComposerImpl;Z)V
