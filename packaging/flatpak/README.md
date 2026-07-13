<!--
SPDX-FileCopyrightText: 2026 Jarrad Hope
SPDX-License-Identifier: MPL-2.0
-->

# Flatpak packaging (`ai.daemon.app`)

Flathub-grade, from-source Flatpak for the Daemon product. The GUI thin client
(`daemon-app`) and the node binaries (`daemon`, `daemon-cli`, `daemon-infer`)
are built from source inside the KDE runtime SDK and all land in `/app/bin`.

- Manifest: [`ai.daemon.app.yml`](ai.daemon.app.yml)
- Cargo vendoring: [`cargo-sources.json`](cargo-sources.json) (generated — do not
  hand-edit; regenerate with `just flatpak-cargo-sources`)
- Vendored generator: [`tools/flatpak-cargo-generator.py`](tools/flatpak-cargo-generator.py)
  (pinned to flatpak-builder-tools `f03a673`)

## Architecture

Targets **`org.kde.Platform` / `org.kde.Sdk` 6.11**: the runtime supplies
prebuilt shared Qt 6.11 (matching the app's `find_package(Qt6 6.11)` floor, with
Qt5Compat). The app builds with `DAEMON_APP_STATIC=OFF` — the same shared-Qt
configuration `daemon-app#default` and `just dev-run` exercise daily, not a new
build flavor. Static Qt remains the story for AppImage/deb/rpm/portable, where no
runtime exists.

Module order (dependencies first):

1. `tinyxml2` — shared lib MicroTeX links via pkg-config
2. `qtkeychain` — Qt6 OS-keychain backend for the server-token store
3. `qmltermwidget` — the embedded-terminal QML plugin (`import QMLTermWidget`)
4. `spirv-headers` — header-only SPIR-V CMake package the Vulkan llama lane needs (see GPU note); pruned at runtime
5. `llama-cpp` — from-source shared llama.cpp (Vulkan-accelerated; see GPU note) into `/app/llama`
6. `daemon-node` — Rust: `daemon --features browser`, `daemon-cli`, `daemon-infer --features llama,mtmd,dynamic-link`
7. `daemon-app` — the Qt GUI, shared-Qt configure, with the vendored deps wired via `-D<DEP>_SOURCE_DIR` (six header/source trees + the sentry-native crash-reporting SDK)

The app's `LocalDaemonLauncher::discoverDaemonBinary()` and the node's
`default_worker_bin()` both resolve siblings next to the running executable, so
one `/app/bin` needs **zero code changes**.

### TUI: not built here

The Flatpak ships **GUI-only** (`-DDAEMON_APP_TUI=OFF`). This deliberately drops
the TUI Meson stack (termpaint / posixsignalmanager / tuiwidgets) from the
manifest for a smaller first cut. `qmltermwidget` is still built — the GUI
Terminal panel needs it independent of the TUI. To add the TUI later, flip
`-DDAEMON_APP_TUI=ON` and add those three Meson modules before `daemon-app`.

### GPU (Vulkan)

The shipped lane is **Vulkan-accelerated llama** (`-DGGML_VULKAN=ON`). No Flatpak
extension and no source-built shader *compiler* is needed — the base SDK already
carries the toolchain ggml's Vulkan backend compiles with:

- **`org.freedesktop.Sdk` 25.08** (the base of `org.kde.Sdk` 6.11) ships
  `/usr/bin/glslc` (shaderc 2025.3, spirv-tools 2025.3, glslang 15.4.0), the
  Vulkan headers (`/usr/include/vulkan/vulkan.h`, `pkg-config vulkan` = 1.4.321),
  and the unversioned `libvulkan.so` dev symlink. So `-DGGML_VULKAN=ON` finds
  `glslc`, compiles its SPIR-V shaders in place, and builds `libggml-vulkan.so`
  during the module build. The llama.cpp pin (`94a220cd6`) carries the upstream
  shader-optimizer mitigations, so shaderc 2025.3 compiles the full shader set.
- The **one** thing the SDK omits is the header-only **`SPIRV-Headers` CMake
  package** that ggml's shader generator (`vulkan-shaders-gen`) `find_package`s.
  It is built from source as the tiny `spirv-headers` module (pinned to the
  Khronos `vulkan-sdk-1.4.321.0` release, matching the SDK's Vulkan), header-only
  — the installed `/include` + `/lib`(`/share`)`/cmake` are dropped by `cleanup`,
  so nothing lands at runtime. It is **not** a shader compiler.
- `llama-cpp` also sets `-DLLAMA_BUILD_APP=OFF`: the upstream unified `llama`
  binary links cli/server impl libs that only build with `LLAMA_BUILD_SERVER=ON`,
  so it would fail to link in this server-less lane. We don't ship that binary
  (daemon-infer links the libraries, not a CLI), and `libmtmd` still builds via
  `LLAMA_BUILD_TOOLS=ON`.
- The `llama-cpp` `post-install` logs the `glslc` version and **fatally asserts**
  `libggml-vulkan.so*` survived the prune (mirroring the `libmtmd.so` guard), so
  a silently CPU-only build fails loudly instead of shipping.

**Runtime split** (loader vs. drivers vs. device):

- **Loader** (`libvulkan.so.1`): from `org.kde.Platform`.
- **ICDs** (the actual GPU drivers): from the `org.freedesktop.Platform.GL.*`
  extension, which Flatpak auto-selects for the runtime.
- **Device nodes**: via `--device=dri` (already granted in `finish-args`).

**Rust `vulkan` cargo feature stays OFF.** `daemon-infer` is built
`--features llama,mtmd,dynamic-link` (no `vulkan`) *on purpose*: `dynamic-link`
means the crate does **not** run its own native llama.cpp build — it links the
separately built shared `libllama`/`libggml*` from `/app/llama` (copied into
`/app/lib` by the `daemon-node` module, `libggml-vulkan.so` included). The
crate's `vulkan` feature only drives the crate-owned CMake build, which this
packaging path replaces; adding it here would do nothing but risk a second,
conflicting native build. (This is specific to this from-prebuilt packaging path,
not a general property of `dynamic-link`.)

GPU offload is **opt-in and degrades to CPU**: the node defaults
`n_gpu_layers = 0` (CPU); set `DAEMON_INFER__N_GPU_LAYERS` to offload, with
graceful CPU fallback when no Vulkan device is visible in the sandbox. CUDA stays
deferred (no Flathub CUDA SDK extension).

### Crash reporting (Sentry) inside the sandbox

The app is built with crash reporting **wired in** (mirroring `daemon-app#default`):
the `sentry-native` 0.15.3 release SDK is add_subdirectory'd via
`-DSENTRY_NATIVE_SOURCE_DIR`, producing `libsentry` (linked into `daemon-app`) and
the out-of-process **`crashpad_handler`** that `Packaging.cmake` installs next to
the binary in `/app/bin` (the co-location `crash::defaultHandlerPath()` expects).
The product DSN is compiled in (`-DDAEMON_APP_SENTRY_DSN`, a public ingest key).

It is **consent-gated and off by default**: nothing is sent until the user opts in
("Send crash reports" in Settings). The crash database lives inside the sandbox
(`<AppDataLocation>/crash-db`); uploads use the network grant already present for
model/API traffic. The node's own crash path (the pure-Rust `sentry` +
`sentry-rust-minidump` crates, always compiled) is present but **left unwired in
this first cut** — the manifest does not thread `DAEMON_SENTRY_DSN` to the spawned
node, so node-side reporting is a runtime no-op; the GUI (the primary crash
surface) is the wired path. Thread the node DSN (e.g. a `--env=DAEMON_SENTRY_DSN`
`finish-arg`, as the Nix bundle wrapper does) to enable it later.

## File-permission / path strategy (verified — no code changes)

Everything the product writes resolves inside the per-app sandbox
(`~/.var/app/ai.daemon.app/…`), so the manifest grants **no `--filesystem`**:

| Concern | Resolves to | How |
| --- | --- | --- |
| App config (`QSettings`) | `~/.var/app/ai.daemon.app/config` | `XDG_CONFIG_HOME` inside the sandbox |
| App data (`AppDataLocation`) | `~/.var/app/ai.daemon.app/data` | `XDG_DATA_HOME` inside the sandbox |
| Node data | `<AppDataLocation>/daemon` | launcher sets `DAEMON_DATA_DIR`; `DAEMON_STORE=sqlite` |
| API socket | `$XDG_RUNTIME_DIR/…` | launcher sets `DAEMON_SOCKET_PATH`; node's `prepare_api_socket()` mkdir's the parent |
| HF model cache | `$XDG_CACHE_HOME/huggingface/hub` | inside the sandbox |

HF models are cached **per-app** inside the sandbox. We deliberately skip a
`--filesystem=xdg-cache/huggingface` grant (that would puncture the sandbox to
the host's shared HF cache); the trade-off is models re-download per app rather
than sharing a host cache.

### `finish-args` (least privilege)

- `--socket=wayland`, `--socket=fallback-x11`, `--share=ipc`, `--device=dri`
- `--share=network` — HF downloads, provider APIs, chat adapters, swarm transport
- `--talk-name=org.freedesktop.secrets` — qtkeychain token store
- No portal talk-name: the Background portal (launch-at-login, below) is always
  reachable, and flatpak-builder-lint rejects an explicit portal talk-name.
- No `--filesystem` grants.

### Launch-at-login inside the sandbox

A direct `~/.config/autostart` write never reaches the host session, so inside
Flatpak the shared autostart controller routes through the **Background portal**
(`org.freedesktop.portal.Background.RequestBackground`) — implemented in
`daemon-app/src/core/platform/autostart/autostart_backend_portal.cpp`, which the
XDG backend delegates to when `runningInsideFlatpak()`. When the portal is
absent/fails it falls back to the pre-portal "managed by your system's Flatpak
permissions" state. Known limitation: the Background portal offers no state
read-back, so the settings toggle reflects the in-session request rather than a
persisted host grant.

## Known sandbox limitations

- **Browser tool** (`daemon --features browser`): chromiumoxide auto-detects a
  Chromium on `PATH`; the sandbox has none, so the browser tool is degraded
  unless a host Chromium is exposed. No Chromium is embedded.
- **VRAM sizing**: the `nvidia-smi` probe is unavailable in the sandbox, so VRAM
  sizing falls back to conservative defaults.
- **GPU**: Vulkan is **enabled** (see GPU section above); offload is opt-in
  (`n_gpu_layers` defaults to 0 / CPU — set `DAEMON_INFER__N_GPU_LAYERS` to
  offload, with graceful CPU fallback when no Vulkan device is present). CUDA
  stays deferred (no Flathub CUDA SDK extension).

## Local build / run / lint

All recipes use the `.#flatpak` devShell (`nix develop .#flatpak`):

```sh
just flatpak-cargo-sources   # regenerate cargo-sources.json from Cargo.lock
just flatpak-build           # flatpak-builder --user --install (pulls the runtime from flathub)
just flatpak-run             # flatpak run ai.daemon.app
just flatpak-bundle          # export build/ai.daemon.app.flatpak
just flatpak-lint            # flatpak-builder-lint manifest (+ repo) + appstream/desktop validation
```

`just flatpak-build` needs network on first run (runtime + SDK extensions from
flathub) and is CPU/time-heavy (Rust workspace + llama.cpp + KSyntaxHighlighting
all from source); it is not part of the fast gates.

## Flathub pre-submission checklist

- [ ] Swap every `type: dir` source (`../../daemon-node`, `../../daemon-app`) for
      a pinned `type: git` `tag` + `commit` (see the `# Flathub:` comments in the
      manifest).
- [ ] Add real `<release>` history with notes to the metainfo (the template ships
      a single stub release).
- [ ] Add `<screenshots>` to the metainfo (Flathub requires at least one).
- [ ] Confirm the OARS `<content_rating>` reflects the shipped app.
- [ ] Fill the homepage/other `<url>` entries once the public site lands.
- [ ] Re-run `just flatpak-lint` (manifest + repo) and clear all real findings.

## Tooling status on this host

`flatpak` + the `flathub` remote are present; `flatpak-builder` comes from the
`.#flatpak` devShell. `flatpak-builder-lint` lives in the `org.flatpak.Builder`
flatpak (installed on demand by `just flatpak-lint`). A full `flatpak-builder`
run downloads the ~3 GB KDE runtime + SDK and compiles the whole product from
source, so it is left to an explicit `just flatpak-build` rather than the
per-change gates; the manifest, `cargo-sources.json`, and metadata validation are
the gates exercised here.
