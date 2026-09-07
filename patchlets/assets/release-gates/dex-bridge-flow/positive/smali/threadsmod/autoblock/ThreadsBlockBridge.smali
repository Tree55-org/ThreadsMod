.class public final Lthreadsmod/autoblock/ThreadsBlockBridge;
.super Ljava/lang/Object;
.source "ThreadsBlockBridge.smali"


# direct methods
.method private constructor <init>()V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method public static passivePreflight(Ljava/lang/Object;Ljava/lang/String;)Ljava/lang/String;
    .locals 2

    :try_preflight_session_start
    check-cast p0, Lfixture/Session;
    :try_preflight_session_end
    .catch Ljava/lang/Throwable; {:try_preflight_session_start .. :try_preflight_session_end} :catch_preflight_session

    :try_preflight_cache_lookup_start
    invoke-static {p0, p1}, Lfixture/CacheLookup;->find(Lfixture/Session;Ljava/lang/String;)Lfixture/Model;

    move-result-object v0
    :try_preflight_cache_lookup_end
    .catch Ljava/lang/Throwable; {:try_preflight_cache_lookup_start .. :try_preflight_cache_lookup_end} :catch_preflight_cache_lookup

    if-nez v0, :preflight_model_ready

    :try_preflight_cache_factory_start
    invoke-static {p0}, Lfixture/CacheFactory;->create(Lfixture/Session;)Lfixture/Cache;

    move-result-object v0
    :try_preflight_cache_factory_end
    .catch Ljava/lang/Throwable; {:try_preflight_cache_factory_start .. :try_preflight_cache_factory_end} :catch_preflight_cache_factory

    const/4 v1, 0x0

    :try_preflight_cache_placeholder_start
    invoke-virtual {v0, v1, p1}, Lfixture/Cache;->getOrPut(Lfixture/Seed;Ljava/lang/String;)Lfixture/Model;

    move-result-object v0
    :try_preflight_cache_placeholder_end
    .catch Ljava/lang/Throwable; {:try_preflight_cache_placeholder_start .. :try_preflight_cache_placeholder_end} :catch_preflight_cache_placeholder

    if-nez v0, :preflight_model_ready

    const-string v0, "placeholder_model_invalid"

    return-object v0

    :preflight_model_ready
    :try_preflight_prepare_start
    invoke-static {v0, p1}, Lthreadsmod/autoblock/ThreadsBlockBridge;->prepareModel(Lfixture/Model;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0
    :try_preflight_prepare_end
    .catch Ljava/lang/Throwable; {:try_preflight_prepare_start .. :try_preflight_prepare_end} :catch_preflight_prepare

    return-object v0

    :catch_preflight_session
    move-exception v0

    const-string v0, "session_model_exception"

    return-object v0

    :catch_preflight_cache_lookup
    move-exception v0

    const-string v0, "cache_lookup_exception"

    return-object v0

    :catch_preflight_cache_factory
    move-exception v0

    const-string v0, "cache_factory_exception"

    return-object v0

    :catch_preflight_cache_placeholder
    move-exception v0

    const-string v0, "cache_placeholder_exception"

    return-object v0

    :catch_preflight_prepare
    move-exception v0

    const-string v0, "bridge_dispatch_exception"

    return-object v0
.end method

.method public static block(Landroid/app/Activity;Ljava/lang/Object;Ljava/lang/String;Lthreadsmod/autoblock/BridgeCallback;)V
    .locals 2

    :try_session_start
    check-cast p1, Lfixture/Session;
    :try_session_end
    .catch Ljava/lang/Throwable; {:try_session_start .. :try_session_end} :catch_session

    :try_cache_lookup_start
    invoke-static {p1, p2}, Lfixture/CacheLookup;->find(Lfixture/Session;Ljava/lang/String;)Lfixture/Model;

    move-result-object v0
    :try_cache_lookup_end
    .catch Ljava/lang/Throwable; {:try_cache_lookup_start .. :try_cache_lookup_end} :catch_cache_lookup

    if-nez v0, :model_ready

    :try_cache_factory_start
    invoke-static {p1}, Lfixture/CacheFactory;->create(Lfixture/Session;)Lfixture/Cache;

    move-result-object v0
    :try_cache_factory_end
    .catch Ljava/lang/Throwable; {:try_cache_factory_start .. :try_cache_factory_end} :catch_cache_factory

    const/4 v1, 0x0

    :try_cache_placeholder_start
    invoke-virtual {v0, v1, p2}, Lfixture/Cache;->getOrPut(Lfixture/Seed;Ljava/lang/String;)Lfixture/Model;

    move-result-object v0
    :try_cache_placeholder_end
    .catch Ljava/lang/Throwable; {:try_cache_placeholder_start .. :try_cache_placeholder_end} :catch_cache_placeholder

    if-nez v0, :model_ready

    const-string v1, "placeholder_model_invalid"

    invoke-static {p3, p2, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V

    return-void

    :model_ready
    invoke-static {p0, p1, v0, p2, p3}, Lthreadsmod/autoblock/ThreadsBlockBridge;->blockModel(Landroid/app/Activity;Lfixture/Session;Lfixture/Model;Ljava/lang/String;Lthreadsmod/autoblock/BridgeCallback;)V

    return-void

    :catch_session
    move-exception v0

    const-string v1, "session_model_exception"

    invoke-static {p3, p2, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V

    return-void

    :catch_cache_lookup
    move-exception v0

    const-string v1, "cache_lookup_exception"

    invoke-static {p3, p2, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V

    return-void

    :catch_cache_factory
    move-exception v0

    const-string v1, "cache_factory_exception"

    invoke-static {p3, p2, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V

    return-void

    :catch_cache_placeholder
    move-exception v0

    const-string v1, "cache_placeholder_exception"

    invoke-static {p3, p2, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V

    return-void

.end method

.method public static blockResolved(Landroid/app/Activity;Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/String;Lthreadsmod/autoblock/BridgeCallback;)V
    .locals 2

    if-nez p2, :resolved_present

    invoke-static {p0, p1, p3, p4}, Lthreadsmod/autoblock/ThreadsBlockBridge;->block(Landroid/app/Activity;Ljava/lang/Object;Ljava/lang/String;Lthreadsmod/autoblock/BridgeCallback;)V

    return-void

    :resolved_present
    :try_resolved_session_start
    check-cast p1, Lfixture/Session;
    :try_resolved_session_end
    .catch Ljava/lang/Throwable; {:try_resolved_session_start .. :try_resolved_session_end} :catch_resolved_session

    :try_resolved_model_start
    check-cast p2, Lfixture/Model;
    :try_resolved_model_end
    .catch Ljava/lang/Throwable; {:try_resolved_model_start .. :try_resolved_model_end} :catch_resolved_model

    invoke-static {p0, p1, p2, p3, p4}, Lthreadsmod/autoblock/ThreadsBlockBridge;->blockModel(Landroid/app/Activity;Lfixture/Session;Lfixture/Model;Ljava/lang/String;Lthreadsmod/autoblock/BridgeCallback;)V

    return-void

    :catch_resolved_session
    move-exception v0

    const-string v1, "session_model_exception"

    invoke-static {p4, p3, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V

    return-void

    :catch_resolved_model
    move-exception v0

    const-string v1, "resolved_model_invalid"

    invoke-static {p4, p3, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V

    return-void
.end method

.method private static prepareModel(Lfixture/Model;Ljava/lang/String;)Ljava/lang/String;
    .locals 2

    :try_model_id_start
    invoke-virtual {p0}, Lfixture/Model;->id()Ljava/lang/String;

    move-result-object v0
    :try_model_id_end
    .catch Ljava/lang/Throwable; {:try_model_id_start .. :try_model_id_end} :catch_model_id

    if-eqz v0, :model_id_mismatch

    invoke-virtual {p1, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v1

    if-eqz v1, :model_id_mismatch

    :try_already_blocked_start
    invoke-static {p0}, Lfixture/BlockState;->isBlocked(Lfixture/Model;)Z

    move-result v0
    :try_already_blocked_end
    .catch Ljava/lang/Throwable; {:try_already_blocked_start .. :try_already_blocked_end} :catch_already_blocked

    if-eqz v0, :model_ready

    const-string v0, "already_blocked_success"

    return-object v0

    :model_ready
    const/4 v0, 0x0

    return-object v0

    :model_id_mismatch
    const-string v0, "model_id_mismatch"

    return-object v0

    :catch_model_id
    move-exception v0

    const-string v0, "model_id_exception"

    return-object v0

    :catch_already_blocked
    move-exception v0

    const-string v0, "already_blocked_exception"

    return-object v0
.end method

.method public static blockModel(Landroid/app/Activity;Lfixture/Session;Lfixture/Model;Ljava/lang/String;Lthreadsmod/autoblock/BridgeCallback;)V
    .locals 13

    move-object/from16 v0, p3

    :try_dispatch_start
    invoke-static {p2, v0}, Lthreadsmod/autoblock/ThreadsBlockBridge;->prepareModel(Lfixture/Model;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0
    :try_dispatch_end
    .catch Ljava/lang/Throwable; {:try_dispatch_start .. :try_dispatch_end} :catch_dispatch

    if-eqz v0, :submit_mutation

    const-string v1, "already_blocked_success"

    invoke-virtual {v1, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v1

    if-eqz v1, :prepared_failure

    move-object/from16 v2, p4

    move-object/from16 v3, p3

    invoke-static {v2, v3}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->success(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;)V

    return-void

    :prepared_failure
    move-object/from16 v2, p4

    move-object/from16 v3, p3

    invoke-static {v2, v3, v0}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V

    return-void

    :submit_mutation
    move-object/from16 v0, p4

    new-instance v3, Lthreadsmod/autoblock/MutationCallback;

    move-object/from16 v1, p3

    invoke-direct {v3, v0, v1}, Lthreadsmod/autoblock/MutationCallback;-><init>(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;)V

    move-object v0, p0
    move-object v1, p2
    move-object v2, p1

    const/4 v4, 0x0
    const-string v5, "fixture_surface"
    const-string v6, "fixture_surface"
    const/4 v7, 0x0
    const/4 v8, 0x0
    const/4 v9, 0x0
    const/4 v10, 0x0
    const/4 v11, 0x0
    const/4 v12, 0x0

    :try_mutation_start
    invoke-static/range {v0 .. v12}, Lfixture/MutationApi;->block(Landroid/content/Context;Lfixture/ModelInterface;Lfixture/Session;Lfixture/MutationEvents;Ljava/lang/Integer;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;I)V
    :try_mutation_end
    .catch Ljava/lang/Throwable; {:try_mutation_start .. :try_mutation_end} :catch_mutation

    return-void

    :catch_dispatch
    move-exception v0

    move-object/from16 v2, p4

    const-string v1, "bridge_dispatch_exception"

    move-object/from16 v0, p3

    invoke-static {v2, v0, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V

    return-void

    :catch_mutation
    move-exception v0

    move-object/from16 v2, p4

    const-string v1, "mutation_exception"

    move-object/from16 v0, p3

    invoke-static {v2, v0, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V

    return-void
.end method
