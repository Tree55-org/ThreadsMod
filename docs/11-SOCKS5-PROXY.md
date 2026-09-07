# SOCKS5 proxy

Patchlet [`080-socks5-proxy`](../patchlets/features/080-socks5-proxy/PATCHLET.md) adds an optional, app-scoped Android VPN transport to the Threads clone.
When the feature is enabled and Android grants VPN consent, the clone's captured IPv4 and IPv6 packets are handed to a pinned tun2socks engine and then to the configured SOCKS5 server.
That covers Java clients and native TCP/UDP stacks without modifying Threads TLS, certificates, request hosts, or the Clone Blocker mirror and write policies.

Proxying is disabled by default.
The feature never installs a global device proxy, never carries another application's traffic, and never changes the official Threads app.

## Why a VPN seam

This APK contains native Tigon/MNS/QUIC code, raw TCP and UDP sockets, WebView/Chromium, and Java URL connections.
Setting Java proxy system properties, or wrapping only the mod's own HTTP client, would leave material network paths outside SOCKS5.
An app-scoped TUN is the common same-UID packet boundary available without altering Threads TLS or its private request code.

## Settings

Open **Clone Blocker settings**, find the **SOCKS5 proxy** card, and tap **Configure proxy**.
The private **SOCKS5 proxy settings** page owns:

- the enabled switch;
- SOCKS5 server host and port;
- an authentication switch with optional username and password;
- the direct bypass list;
- the current routing and protection status line;
- **Save & connect**, which also triggers Android VPN consent, and **Disconnect**.

Server host accepts a numeric IPv4 or IPv6 address, or an IDNA hostname of at most 253 ASCII bytes.
Port is `1` through `65535`, defaulting to `1080`.
SOCKS5 username and password are optional and bounded to 1-255 ASCII bytes each, matching the protocol's fields.
The validated configuration is committed as one atomic snapshot.
Credentials are encrypted with an Android Keystore AES-GCM key under the alias `threadsmod_proxy_config_aes_v1`, and the tunnel receives a bounded in-memory configuration document rather than a file, so no plaintext credential is ever written to disk, a log, a report, a diagnostic, or an exception copy.

That encryption protects local storage only.
SOCKS5 is not itself an encrypted transport: the proxy and the network path to it can observe SOCKS authentication and destination metadata.
HTTPS still protects Threads request content, but use a proxy and a network path you trust.

## Bypass rules

The bypass list is exact packet routing, one numeric IPv4/IPv6 address or CIDR per line.
It is limited to 64 canonical rules and 4,096 UTF-16 units.
Examples:

```text
192.0.2.25
198.51.100.0/24
2001:db8:1234::/48
```

Listed ranges go directly; all other captured traffic goes through SOCKS5.
Blank lines are ignored.

Domain names, wildcards, URLs, app names, ports and protocols are rejected, because none of them can be represented truthfully as an exact IP-layer exclusion.
A CDN or an encrypted DNS path can map one hostname to changing or shared addresses, so a domain checkbox would draw a leak boundary that does not match the packets.

The selected numeric SOCKS endpoint is always a direct infrastructure exception, so the tunnel cannot route into itself; at most 16 resolved endpoint addresses are accepted.
Once Android consent exists, a full-route no-consumer TUN owns app traffic first.
If the server is entered as a hostname, its DNS lookup then uses only a bounded explicit non-VPN Android `Network`, while that blackhole is still active and before the forwarding TUN starts.
Use a numeric server address for the strictest and most reproducible boundary.

On Android 33 and above the planner installs default routes and calls `excludeRoute` for each rule.
Older releases have no exclusion API, so the planner emits the exact CIDR complement instead, bounded at 4,096 routes.
The combined user policy and resolved infrastructure set is bounded at 80 excluded prefixes.
Route overflow fails closed rather than silently widening or narrowing the exclusion set.

## Status vocabulary

The runtime exposes a credential-free status token, and [`ProxyController`](../patchlets/assets/autoblock/java/threadsmod/proxy/ProxyController.java) maps each token to one fixed user-facing line.
The two words that matter are **Paused** — app traffic is blocked — and **Unprotected** — direct traffic is possible.

| Token | Status line | Meaning |
|---|---|---|
| `connected` | VPN routes are installed and the SOCKS5 engine thread is live; endpoint reachability is not verified. | Routes accepted, worker live |
| `starting` | Installing VPN routes and checking SOCKS5 engine liveness… | Transient |
| `paused_config` | **Paused:** proxy configuration needs review. | Traffic blocked |
| `paused_resolution` | **Paused:** the SOCKS5 server could not be resolved. | Traffic blocked |
| `paused_routes` | **Paused:** bypass routes could not be installed safely. | Traffic blocked |
| `paused_native` | **Paused:** the SOCKS5 tunnel engine is unavailable. | Traffic blocked |
| `paused_guard_active` | **Paused:** a full-route guard is active; app traffic remains blocked. | A newly established full-route no-consumer guard owns app traffic |
| `paused_guard_retained` | **Paused:** the prior full-route guard is retained; app traffic remains blocked. | Android refused the replacement, but the interface that stayed is itself a full-route guard |
| `unprotected_prior_routing` | **Unprotected:** Android refused the fresh full-route guard; prior VPN routing is retained and earlier numeric DIRECT exclusions may remain. | The interface that stayed is an older *forwarding* TUN, not a fresh blackhole; never reported as connected |
| `paused_vpn` | **Unprotected:** Android could not establish the VPN; direct traffic may continue. | Reserved exclusively for the no-TUN outcome |
| `disabled` | **Unprotected:** proxy service is inactive; direct traffic may continue. | Reported whenever the configuration stays enabled but the runtime is not |

Despite its name, `paused_vpn` is an **Unprotected** state, not a pause: there is no TUN at all, so nothing is holding traffic back.
The `disabled` row is why revoke, service destruction and a notification **Disconnect** cannot leave stale **Starting** text on screen.
`paused_guard_retained` and `unprotected_prior_routing` are deliberately distinct: both mean Android rejected a fresh guard, but only the first still has a blackhole underneath it.

If the saved configuration cannot be read, or its encrypted state is uncertain, the page reports **Unprotected** and warns that direct traffic may continue until Android VPN protection is active.

## Fail-closed behaviour

Every enable or reconfiguration requests a fresh full-route no-consumer guard before any endpoint work.
After Android has granted VPN authority and the service can own a TUN, an invalid or unreadable configuration, uncertain encrypted state, route overflow, tunnel startup failure, upstream failure, or missing SOCKS5 UDP support does not authorize ordinary direct traffic.
The service keeps a bounded blackhole or pause until the user repairs the configuration or explicitly disables proxying.
The implementation never calls Android's `allowBypass` API.

The status distinguishes routing from reachability.
"VPN routes are installed" means only that Android accepted the routes and the JNI worker currently reports live; it does not prove SOCKS authentication, endpoint reachability, or a successful Threads request.
A 500 ms liveness watchdog replaces a failed worker with the full-route guard whenever Android accepts that replacement.

Proxy Settings independently polls the credential-free runtime token every 500 ms, and only while the Activity is resumed.
It rebuilds the complete status text only when that token changes, cancels polling on pause, and checks the boolean result of both the initial and the recurring `Handler.postDelayed`.
A rejected enqueue stops polling and visibly reports **Unavailable: live proxy status refresh stopped**, telling the user to reopen the page before relying on its status.
A proxy-hostname lookup already executing through the disclosed direct infrastructure network cannot be cancelled on this Android API floor, but generation fences prevent a stale result from installing routes or starting the native engine.

SOCKS5 UDP ASSOCIATE is required for DNS, UDP and QUIC traffic.
A TCP-only SOCKS server can therefore make parts of Threads unavailable; that is preferable to silently leaking those packets outside the proxy.

## Android constraints

Android displays a system-owned VPN consent dialog on first activation.
Only one VPN can be active per Android user or profile, so connecting this feature replaces or conflicts with any other VPN.
A persistent foreground notification, carrying its own **Disconnect** action, is required while the tunnel owns the VPN interface.

Before the user grants consent, or when Android refuses to establish any VPN interface, the mod has no system authority to stop direct app traffic.
Settings labels that state as **Unprotected** and warns that direct traffic may continue.
It is never described as paused or protected.

The service scopes the VPN with `addAllowedApplication` for the clone's own package only — `app.tree55.threads` — which covers processes running under the clone's normal UID.
Android isolated Chromium processes, and traffic offloaded to system or Google Play services, can use other UIDs; OEM networking can also differ.
"All Threads traffic" is therefore not a release claim until an exact signed APK passes device packet capture across TCP, UDP/QUIC, DNS, WebView, process restart, reconnect, proxy failure, IPv4/IPv6 and bypass cases.
The official Threads app and every other application stay outside the tunnel by design.

## Native dependency and update path

The arm64 engine is `heiher/hev-socks5-tunnel` at commit `a404c11cd61d8e29e6f4c590b7e659d127fb843e`, with every submodule commit pinned in the asset's provenance record and the output library SHA-256 pinned in the exact resolution.
The only source patch changes the JNI input from a plaintext configuration path to a bounded in-memory document passed to `hev_socks5_tunnel_main_from_str`.
The binary is built with Android NDK `27.1.12297006` and 16 KiB load alignment, and two independent fresh build directories must reproduce SHA-256 `3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`.
Its MIT license, the combined HEV and lwIP notice shipped inside the APK, and the build provenance are stored beside the canonical asset.

For a future Threads APK, the AI updater may propose a new `BarcelonaAppShell.attachBaseContext` anchor and manifest placement, but it cannot reuse an unmatched anchor, change the library hash, relax route or credential checks, or mark packet-capture evidence passed.
[08-AI-DRIVEN-PATCHLETS.md](08-AI-DRIVEN-PATCHLETS.md) describes the boundary the updater works inside.
Replay must start from the pristine exact source SHA-256 and apply the complete cataloged series.

## Release gates

The broad final-DEX forbidden-string scanner matches case-insensitive substrings.
The pristine Threads APK already contains `ProxyServiceBroadcaster.getSocksProxyPort()`, so a broad lowercase `socksProxyPort` prohibition would reject unchanged host code and could not prove the Java system-property fallback key absent.
The resolution binds that pristine method explicitly, and the broad list therefore omits `socksProxyPort` while still forbidding `allowBypass`, `socksProxyHost`, `java.net.useSystemProxies`, `threadsmod_proxy_username` and `threadsmod_proxy_password`.
Canonical proxy Java and the nine signed targeted classes that carry proxy code — the host Application shell, `com.threadsmod.ProxySettingsActivity`, and the seven `threadsmod.proxy` classes — instead forbid the exact-case fallback set `allowBypass(`, `System.setProperty(`, `ProxySelector.setDefault(`, `socksProxyHost`, `socksProxyPort` and `java.net.useSystemProxies`.
All other broad final-DEX prohibitions remain blocking.

Readable decompilation does not own the bootstrap proof.
Frozen JADX 1.5.6 can skip every instruction unit in `BarcelonaAppShell.attachBaseContext`, producing secondary output with no `ProxyBootstrap.install` call in it at all, so `setShowInconsistentCode(true)` is a secondary cross-check rather than an authority.
A separate hash-pinned raw signed-Dex bootstrap-flow inspector, with 13 positive and negative fixture cases, owns the exact superclass call, the immediately adjacent bootstrap call, the same parameter-derived context register, the original next field read, the sole bootstrap caller, the absence of any alternate branch, handler or try entry, and the exact absence of every fallback reference.
That inspector recognizes only explicitly reviewed layouts and fails closed on layout drift.

Release history, artifact identity, sizes and hashes live in [CHANGELOG.md](CHANGELOG.md).
The build in which this feature was the headline change is the historical `socks5-proxy` build recorded there; its replay directory `work/patchlet-socks5-proxy-20260902-d` and its published bytes are local-only and are not part of this repository.
An earlier replay of the same series, `work/patchlet-socks5-proxy-20260902-c`, is the failure evidence behind the raw signed-Dex gate above: it passed idempotency, rebuild, alignment and signing, and still failed closed at the release gates.

## Validation boundary

Release-bound evidence for this feature must include all of:

- schema and catalog validation, exact rewrite counts, full-series content-identical reapplication, and host policy tests;
- every ordered exact-count targeted JADX recovery, with no skipped markers;
- the authoritative raw signed-Dex Application-bootstrap flow with its positive and negative fixture contract;
- canonical and recovered proof of `paused_guard_active`, `paused_guard_retained`, `unprotected_prior_routing`, exclusive no-TUN `paused_vpn`, and the enabled-config/runtime-disabled fallback, each with its truthful message;
- canonical and recovered proof of lifecycle-bounded 500 ms Settings polling, with change-only full refresh and checked Handler rejection;
- private component checks;
- the exact-SHA pristine collision proof plus the exact-case signed proxy fallback negatives;
- preservation of every original native library and exactly one pinned arm64 library addition;
- AArch64 ELF and 16 KiB alignment, plus the archive, DEX, signature and signer gates;
- an isolated no-permission proxy Settings Activity probe.

Those are static and isolated-UI checks.
They do not prove live proxy connectivity or packet coverage.

No published build has ever been installed or run on a device: every published release records `runtimeValidation: not-run`.
The only device evidence anywhere in the series is an isolated emulator Activity-construction probe on a review candidate, which exercises no proxy behaviour.
Android VPN consent, a controlled live SOCKS5 endpoint, authentication, DNS/TCP/UDP/QUIC behaviour, reconnect and failure handling, and independent packet capture have never been exercised.
Patching and re-signing the APK also voids Meta's signature.
A real device, a controlled SOCKS5 endpoint and independent packet capture remain the required runtime evidence.
