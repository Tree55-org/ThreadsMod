.class public final Lcom/instagram/barcelona/app/BarcelonaAppShell;
.super Landroid/app/Application;
.source "BarcelonaAppShell.java"


# virtual methods
.method public final attachBaseContext(Landroid/content/Context;)V
    .registers 20

    move-object/from16 v4, p0

    move-object/from16 v0, p1

    invoke-super {v4, v0}, Landroid/content/ContextWrapper;->attachBaseContext(Landroid/content/Context;)V

    # TRY_START_MARKER
    :bootstrap_entry
    invoke-static {v0}, Lthreadsmod/proxy/ProxyBootstrap;->install(Landroid/content/Context;)V
    # TRY_END_MARKER

    sget-object v3, LX/319;->A05:LX/319;

    # ALT_ENTRY_MARKER
    # FALLBACK_MARKER
    return-void

    # HANDLER_MARKER
.end method
