# 080 SOCKS5 proxy

Revision 3 separates four routing topologies that revision 2 reported too broadly. `paused_guard_active` means a newly established full-route no-consumer guard owns app traffic; `paused_guard_retained` means the previous full-route guard remains installed. Both are **Paused** and keep app traffic blocked. `unprotected_prior_routing` means Android refused the fresh guard while an older forwarding TUN remains active; status must say **Unprotected**, identify prior routing, and warn that its earlier numeric DIRECT exclusions may remain. `paused_vpn` is reserved exclusively for the no-TUN outcome and must say that the VPN is inactive and direct traffic may continue. An enabled configuration paired with runtime `disabled` is likewise explicitly **Unprotected** and inactive with direct traffic possible, preventing a stale **Starting** claim after revoke, service destruction, or notification disconnect. Proxy Settings now performs lifecycle-bounded status polling every 500 ms: polling starts on resume, stops on pause, reads the credential-free runtime token each tick, and rebuilds the full status only when that token changes. Both the initial and recurring `Handler.postDelayed` results are checked; rejection stops polling and visibly reports **Unavailable** so stale text cannot be relied on.

The host bootstrap itself remains exact-version data. The current 444 resolution binds `BarcelonaAppShell` in `classes6.dex`, its reviewed original entry prefix and `LX/0143;->A06:LX/0143;` next-field anchor; the historical 415 resolution binds a different DEX and field. Patchlet 090's raw-Dex inspector recognizes only those explicitly reviewed layouts and still fails closed on any new layout drift.

## Purpose

Add an optional SOCKS5 transport to the separate-ID Threads clone without modifying individual Threads clients, TLS, request endpoints, or the official application. A private Android `VpnService` captures the clone UID's IPv4/IPv6 traffic and passes it to one pinned arm64 tun2socks library. A private Settings activity owns validated server, encrypted optional authentication, numeric direct-bypass rules, VPN consent, status, connect, and disconnect.

The feature is disabled by default. Enabling it is not itself VPN authority: Android's visible `VpnService.prepare` consent remains mandatory. Before approval, or if Android cannot establish any VPN interface, the proxy is inactive and direct traffic may continue; the UI says so explicitly.

## Why a VPN seam

This exact APK contains native Tigon/MNS/QUIC, raw TCP and UDP sockets, WebView/Chromium, and Java URL connections. Java proxy properties or wrapping only the mod's HTTP client would leave material network paths outside SOCKS5. The app-scoped TUN is the common same-UID packet boundary available without altering Threads TLS or private request code.

The exact source-APK resolution owns one early call immediately after the real `BarcelonaAppShell.attachBaseContext(Context)` superclass call. Stable bootstrap code contains no obfuscated Threads descriptors.

## Configuration contract

- server: numeric IPv4/IPv6 or bounded IDNA hostname;
- port: `1..65535`;
- optional SOCKS5 username/password: bounded ASCII protocol fields;
- bypass: at most 64 canonical numeric IPv4/IPv6 addresses or CIDRs and 4,096 UTF-16 units;
- storage: one validated atomic snapshot, AES-GCM credential encryption with an Android Keystore key, and a separate fail-closed enabled/uncertainty guard;
- no plaintext native configuration file, credential log, URL, diagnostic, report, backup, or exception copy.

Domain, wildcard, URL, application, port, and protocol exclusions are rejected because a packet route cannot enforce them exactly. The selected numeric SOCKS endpoint is the sole mandatory direct infrastructure route. Once consent exists, a full-route no-consumer TUN owns app traffic before connection work starts. Hostname resolution needed to select the endpoint uses only a bounded explicit non-VPN Android `Network` while that blackhole remains active and before the forwarding TUN; a numeric server is the strictest option.

## Routing and failure contract

The service uses `addAllowedApplication` for only the clone package, installs IPv4 and IPv6 addresses/routes plus captured DNS, and never invokes `allowBypass`. API 33+ uses explicit route exclusion; older Android receives a deterministic bounded complement of the same excluded CIDRs. Route explosion fails closed.

The native engine is `heiher/hev-socks5-tunnel` at exact commit `a404c11cd61d8e29e6f4c590b7e659d127fb843e` and pinned submodule commits. Its reviewed JNI-only patch passes bounded YAML from memory to `hev_socks5_tunnel_main_from_str`. The build removes only the linker's workspace-dependent GNU build-ID note; two independent fresh directories must then reproduce the arm64 SHA-256 `3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`. AArch64 and 16 KiB load-segment alignment remain blocking release gates.

TCP uses SOCKS5 CONNECT and UDP/QUIC requires SOCKS5 UDP ASSOCIATE. After Android has established VPN authority and a TUN can be owned, configuration, credentials, routes, engine startup, upstream, or UDP failures do not authorize direct traffic. The service retains a bounded blackhole/pause until the user repairs or explicitly disables the proxy. If Android cannot establish the VPN itself, the UI reports an unprotected state instead of making a kill-switch claim it cannot enforce.

Every CONNECT first requests a fresh full-route guard. A newly established guard reports `paused_guard_active`; if Android rejects replacement while the previous guard remains, it reports `paused_guard_retained`. Both are fail-closed pauses. A retained forwarding interface reports `unprotected_prior_routing`; it is not a fresh blackhole and its earlier numeric DIRECT exclusions may remain. With no TUN, `paused_vpn` reports that the VPN is inactive and direct traffic may continue. Enabled configuration with runtime `disabled` is also unprotected/inactive, including after revoke, destroy, or notification disconnect. A live JNI worker proves only worker liveness, not SOCKS authentication or reachability; Settings and the foreground notification say so, and a separate 500 ms watchdog attempts a guard transition on observed native death. While Settings is resumed, its own 500 ms poll observes only the runtime token and refreshes complete status text only on change; pause cancels the poll, and a rejected initial or recurring Handler enqueue visibly changes the page to **Unavailable**. A non-VPN proxy-hostname lookup already in flight cannot be recalled, but generation fences forbid its stale result from installing routes or starting JNI.

## Ownership

Patchlet 080 alone owns:

- `Lthreadsmod/proxy/`;
- `Lcom/threadsmod/ProxySettingsActivity;`;
- the private VPN service and proxy Settings manifest components;
- the exact post-super Application bootstrap rewrite;
- every `threadsmod_proxy_*` preference and Keystore alias;
- `lib/arm64-v8a/libhev-socks5-tunnel.so`;
- `assets/threadsmod/licenses/hev-socks5-tunnel-and-lwip.txt`, the hash-pinned
  combined HEV MIT and lwIP SICS three-clause BSD APK notice;
- its native source patch, provenance, license, build tool, and static/runtime gates.

Patchlet 050 continues to own the main Settings Activity. Its only proxy-related responsibility is the compact navigation card that launches patchlet 080's private activity; patchlet 080 owns the destination and all proxy state.

## Version update

For a new APK digest, run `RESOLVE-SOCKS5-PROXY.md` against a pristine decode. Human review must confirm the manifest Application, post-super hook/register liveness, private component placement, foreground-service contract, native ABI compatibility, and exact rewrite counts. AI may propose bounded candidate/evidence IDs only; it cannot edit the production decode, replace the library, relax routing, or approve runtime packet coverage.

## Release and runtime boundary

Blocking static evidence includes catalog/schema/ownership, canonical host tests, exact hook/manifest rewrite state, full-series content-identical reapplication, signed-Dex bootstrap/classes, exact four-topology routing/status mapping plus enabled-config/runtime-disabled fallback, lifecycle-bounded 500 ms Settings refresh with runtime-token change gating and checked Handler rejection, component privacy, original-native preservation plus exactly one pinned addition, AArch64 ELF and 16 KiB alignment, archive/DEX/signature/signer checks, and isolated no-permission proxy Activity launch.

The signed archive must also contain exactly one resolution-owned combined
HEV/lwIP notice at the reviewed asset path while every source asset outside the
existing DEX replacement exclusion remains byte-identical.

Static same-UID routing is not proof that every packet uses the proxy. Isolated Chromium UIDs, system/GMS-offloaded traffic, OEM networking, live DNS, UDP/QUIC, server behavior, reconnects, and failures require independent packet capture on the exact signed candidate. Android also supports only one active VPN per user/profile. Until that runtime matrix passes, documentation must state the boundary and must not claim universal Threads traffic coverage.
