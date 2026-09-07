.class public final Lcom/instagram/barcelona/app/BarcelonaAppShell;
.super Landroid/app/Application;
.source "BarcelonaAppShell.java"


# virtual methods
.method public final attachBaseContext(Landroid/content/Context;)V
    .registers 24

    const/4 v2, 0x0

    move-object/from16 v1, p1

    invoke-static {v1, v2}, LX/0330;->A0m(Ljava/lang/Object;I)V

    move-object/from16 v0, p0

    invoke-super {v0, v1}, Landroid/content/ContextWrapper;->attachBaseContext(Landroid/content/Context;)V

    # TRY_START_MARKER
    :bootstrap_entry
    invoke-static {v1}, Lthreadsmod/proxy/ProxyBootstrap;->install(Landroid/content/Context;)V
    # TRY_END_MARKER

    sget-object v1, LX/0143;->A06:LX/0143;

    # ALT_ENTRY_MARKER
    # FALLBACK_MARKER
    return-void

    # HANDLER_MARKER
.end method
