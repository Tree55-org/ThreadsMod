# Native SOCKS5 tunnel provenance

`lib/arm64-v8a/libhev-socks5-tunnel.so` is built from the MIT-licensed
[`heiher/hev-socks5-tunnel`](https://github.com/heiher/hev-socks5-tunnel)
repository at exact commit `a404c11cd61d8e29e6f4c590b7e659d127fb843e`.

Pinned submodules:

- `src/core`: `162dd996299fc2d2bff2dd63728f8a2cd71ed31a`
- `third-part/hev-task-system`: `328f35d903221b51811b3d02b277d665dfbdc75f`
- `third-part/lwip`: `2a11c14c7a32887af25a034e82ef18b0b12076ac`
- `third-part/yaml`: `efa36117a8646d26d12b58e05bac472d7854a70d`

The canonical `hev-config-string.patch` changes only the Android JNI wrapper:
the first `String` argument is treated as an in-memory ASCII configuration
instead of a filesystem path. This prevents proxy credentials from being
written to a plaintext cache file. The tunnel engine and protocol behavior are
otherwise unchanged.

Build inputs:

- Android NDK `27.1.12297006`
- `APP_ABI=arm64-v8a`
- `APP_PLATFORM=android-28`
- `APP_CFLAGS=-O3 -DPKGNAME=threadsmod/proxy -DCLSNAME=Socks5VpnService`
- flexible page sizes enabled by upstream `Application.mk`

The final canonical library is normalized with the pinned NDK's
`llvm-objcopy --remove-section=.note.gnu.build-id`. Two clean builds were
otherwise byte-identical but the linker note included a workspace-dependent
20-byte identifier. Removing that non-loadable note makes the canonical bytes
reproducible across fresh paths and also prevents a local build path from
affecting the artifact. The normalized SHA-256 is
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`.

The release resolution pins the resulting library hash. The release gate must
preserve every source-APK native library byte-for-byte, admit exactly this one
owned addition, verify its ELF machine and JNI class strings, and require
16 KiB load-segment alignment.

`NOTICE.hev-socks5-tunnel-and-lwip.txt` is the canonical APK-distributed notice.
It combines the exact HEV MIT notice from the pinned source root with the SICS
three-clause BSD notice from pinned `third-part/lwip/LICENSE`. The patchlet
installs that hash-pinned notice at
`assets/threadsmod/licenses/hev-socks5-tunnel-and-lwip.txt` so an APK-only
distribution carries both required notices.
