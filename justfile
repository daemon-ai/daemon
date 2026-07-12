# Cross-repo tasks for the daemon superproject. Run from the repo root.
# Submodule-aware flake commands need `?submodules=1`; the recipes below add it.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

system := `nix eval --impure --raw --expr 'builtins.currentSystem'`

# List recipes.
default:
    @just --list

# --- builds ---------------------------------------------------------------

# Build the daemon host + operator CLI (debug) in the daemon-node dev shell.
build-node:
    cd daemon-node && nix develop --command cargo build -p daemon -p daemon-cli

# Build the Qt GUI client (release, via its flake).
build-app:
    nix build ./daemon-app#default --out-link result-app

# Build the Qt TUI client (release, via its flake).
build-tui:
    nix build ./daemon-app#tui --out-link result-tui

# Build the Qt WebAssembly GUI client (static browser artifacts, via its flake).
build-wasm:
    nix build ./daemon-app#wasm --out-link result-app-wasm

# Build everything the E2E suite needs.
build-all: build-node build-app build-tui

# Build the client bundles that co-package the daemon host binary (so first-run "Local" can spawn a
# local daemon without a separate install - user story CON-1b). Submodule-aware, like the codec.
bundle:
    nix build ".?submodules=1#bundled-app" --out-link result-bundled-app
    nix build ".?submodules=1#bundled-tui" --out-link result-bundled-tui

# Build the hosted-node OCI image: the daemon serving its own browser (WASM) GUI on one origin, as
# the docker-archive a hosting provider ingests (docs/hosted-node-image.md). Submodule-aware.
# Load + run locally: `podman load -i result-image`.
build-image:
    nix build ".?submodules=1#hosted-node-oci" --out-link result-image

# --- publishing (hosted-node image; docs/hosted-node-image.md §5) ---------
# Push the built OCI docker-archive to a registry and record the immutable DIGEST that
# node_versions.image_ref pins (tags are labels; the digest is the contract - hosted-nodes spec
# §8.1.5). Registry/repo are parameterized (no personal accounts baked in); IMAGE_ORG has no
# default and MUST be set explicitly. Credentials come from the environment only, never stored:
#   REGISTRY_USER + REGISTRY_PASSWORD   -> skopeo --dest-creds / --creds
#   REGISTRY_AUTH_FILE                  -> skopeo --authfile (e.g. a prior `skopeo login` / CI)
# skopeo + jq come from the superproject devShell (`nix develop`).
REGISTRY := env_var_or_default("REGISTRY", "ghcr.io")
IMAGE_ORG := env_var_or_default("IMAGE_ORG", "")
IMAGE_NAME := env_var_or_default("IMAGE_NAME", "daemon-hosted-node")

# Build (if needed) then push result-image and record the pinnable digest to stdout + a file.
# Usage:  just push-image IMAGE_ORG=daemon-ai
# Env:    CHANNEL=canary appends a `-canary` tag suffix (same repo; digest is the contract, so
#         promotion is a node_versions DB action, no re-push). REGISTRY_INSECURE=1 targets a
#         plain-HTTP registry (localhost dry-run; see `verify-push`).
push-image: build-image
    #!/usr/bin/env bash
    set -euo pipefail
    org="{{IMAGE_ORG}}"
    if [ -z "$org" ]; then
      echo "error: set IMAGE_ORG (expected production value: daemon-ai once the GitHub org is confirmed)" >&2
      echo "usage: just push-image IMAGE_ORG=daemon-ai" >&2
      exit 1
    fi
    repo="{{REGISTRY}}/${org}/{{IMAGE_NAME}}"
    # skopeo needs a trust policy; nixpkgs ships none and a NixOS host has no
    # /etc/containers/policy.json (same caveat as podman - hosted-node-image.md §4). Honour an
    # explicit SKOPEO_POLICY, else an existing system/user policy, else synthesize the standard
    # accept-all default (Docker's own default) in a temp file.
    policy=()
    if [ -n "${SKOPEO_POLICY:-}" ]; then
      policy=(--policy "$SKOPEO_POLICY")
    elif [ ! -e "${HOME:-/root}/.config/containers/policy.json" ] && [ ! -e /etc/containers/policy.json ]; then
      pf="$(mktemp)"; trap 'rm -f "$pf"' EXIT
      printf '{"default":[{"type":"insecureAcceptAnything"}]}\n' > "$pf"
      policy=(--policy "$pf")
    fi
    # Tag = the bundle version label (skopeo surfaces it reliably; a docker-archive's RepoTags are
    # not), with SemVer build-metadata '+' -> '_' exactly as the flake stamps the OCI tag.
    ver="$(skopeo "${policy[@]}" inspect docker-archive:result-image \
      | jq -r '.Labels["org.opencontainers.image.version"]')"
    base_tag="${ver//+/_}"
    tag="${base_tag}${CHANNEL:+-$CHANNEL}"
    dest="docker://${repo}:${tag}"
    # Auth + TLS flags built from the env only (nothing is written into the tree).
    copy_auth=(); inspect_auth=()
    if [ -n "${REGISTRY_AUTH_FILE:-}" ]; then
      copy_auth+=(--authfile "$REGISTRY_AUTH_FILE"); inspect_auth+=(--authfile "$REGISTRY_AUTH_FILE")
    fi
    if [ -n "${REGISTRY_USER:-}" ] && [ -n "${REGISTRY_PASSWORD:-}" ]; then
      copy_auth+=(--dest-creds "${REGISTRY_USER}:${REGISTRY_PASSWORD}")
      inspect_auth+=(--creds "${REGISTRY_USER}:${REGISTRY_PASSWORD}")
    fi
    copy_tls=(); inspect_tls=()
    if [ "${REGISTRY_INSECURE:-0}" = "1" ]; then
      copy_tls=(--dest-tls-verify=false); inspect_tls=(--tls-verify=false)
    fi
    echo "push-image: copying result-image -> ${dest}"
    skopeo "${policy[@]}" copy "${copy_auth[@]}" "${copy_tls[@]}" docker-archive:result-image "${dest}"
    # Read the registry manifest digest back. Uses `jq -r .Digest` rather than skopeo's Go-template
    # --format, whose double-brace syntax collides with just's own interpolation inside recipes.
    digest="$(skopeo "${policy[@]}" inspect "${inspect_auth[@]}" "${inspect_tls[@]}" "${dest}" | jq -r '.Digest')"
    ref="${repo}@${digest}"
    mkdir -p dist
    printf '%s\n' "$ref" > dist/hosted-node-digest.txt
    echo "push-image: pushed  ${repo}:${tag}"
    echo "push-image: image_ref = ${ref}"
    echo "push-image: recorded -> dist/hosted-node-digest.txt   (paste into node_versions API as image_ref)"

# Offline dry-run: prove the whole push->digest pipeline with no real registry and no credentials.
# Spins up a throwaway `registry:2` on 127.0.0.1:5000 under rootless podman, runs push-image
# against it insecurely, prints the recorded digest, then tears the registry down. If podman is
# unavailable, the docs describe the zero-dependency `oci:` layout fallback. NOTE the digest from a
# dry-run is a pipeline proof only - the real node_versions value comes from the production push.
verify-push: build-image
    #!/usr/bin/env bash
    set -euo pipefail
    port=5000; name=hosted-node-registry-dryrun
    podman run -d --rm --name "$name" -p "127.0.0.1:${port}:5000" docker.io/library/registry:2 >/dev/null
    trap 'podman stop "$name" >/dev/null 2>&1 || true' EXIT
    for _ in $(seq 50); do
      curl -fsS "http://127.0.0.1:${port}/v2/" >/dev/null 2>&1 && break
      sleep 0.2
    done
    REGISTRY_INSECURE=1 just REGISTRY="127.0.0.1:${port}" IMAGE_ORG=dryrun push-image
    echo "verify-push: OK - pipeline proven offline; recorded digest:"
    cat dist/hosted-node-digest.txt

# --- packaging --------------------------------------------------------------
# Shippable installers with the app+node bundle embedded (flake.nix bundle matrix): each target
# that can carry the daemon does. Linux packages ship bin/{daemon-app,daemon,daemon-infer,
# daemon-cli}; the NSIS installer ships the same set including daemon-infer.exe (the llama worker,
# cross-built for x86_64-pc-windows-gnu) plus its ggml/llama/mtmd DLLs + MinGW runtime in bin\
# (vulkan-1.dll excluded - CPU fallback on driverless hosts); the DMG fills the same contract on a
# mac host with the Metal worker (daemon-app/packaging/macos/README.md). APK/WASM stay thin remote
# clients by design.

# Linux installers (deb + rpm + AppImage + zsync) with the node bundle embedded.
package-linux:
    nix build ".?submodules=1#package-linux" --out-link result-package-linux

# The one-file portable bundle (unpack-anywhere tree + .tar.zst).
package-portable:
    nix build ".?submodules=1#package-portable" --out-link result-package-portable
    nix build ".?submodules=1#package-portable-tarball" --out-link result-package-portable-tarball

# Windows NSIS installer (cross-built; verify on real Windows - wine is unreliable here).
package-windows:
    nix build ".?submodules=1#package-nsis" --out-link result-package-windows

# Composed Windows E2E under wine: silent-install the bundled NSIS installer into a throwaway
# prefix and validate the full co-located flow - installed tree has all three exes, daemon +
# daemon-cli --version, the app spawns the co-located daemon.exe and connects over the named pipe
# (DAEMON_APP_READY ok), a daemon-cli status call over that pipe, and the uninstaller. Best-effort:
# wine is emulation, not Windows (and segfaults inside sandboxed shells) - failures are reported,
# not gating. Verify installers on a real Windows host for release.
smoke-windows:
    nix run ".?submodules=1#smoke-windows"

# macOS DMG (deb/rpm/NSIS twin) with the node bundle embedded. Mac host only: the
# DragNDrop generator shells out to hdiutil/codesign, and the attr is aarch64-darwin
# only. No-ops on Linux so `package-*` calls stay portable.
package-dmg:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "$(uname -s)" != "Darwin" ]; then
      echo "package-dmg: macOS host only (hdiutil/codesign); skipping on $(uname -s)" >&2
      exit 0
    fi
    nix build ".?submodules=1#package-dmg" --accept-flake-config --out-link result-package-dmg

# Everything packageable from this Linux host.
package-all: package-linux package-portable package-windows

# --- cache seeding (daemon-ai.cachix.org) ---------------------------------
# Build (reusing the local store) and push the heavy release + toolchain closures to the daemon-ai
# Cachix cache so CI and other machines pull them instead of rebuilding. The write token is read
# from .env (CACHIX_KEY -> CACHIX_AUTH_TOKEN, the variable the cachix CLI expects) and never
# printed. Submodule-aware attrs use `.?submodules=1#...`; the daemon-app-only attrs (apk / wasm /
# the static-Qt build stacks) build straight from ./daemon-app, and the daemon-node cross-built
# Windows engine workers build straight from ./daemon-node. Also pushes the daemon-node and
# daemon-app devShell closures so CI's `nix develop` pulls instead of rebuilding.
cache-push:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f .env ] || { echo "cache-push: .env not found (needs CACHIX_KEY)" >&2; exit 1; }
    set -a; . ./.env; set +a
    : "${CACHIX_KEY:?cache-push: CACHIX_KEY missing from .env}"
    export CACHIX_AUTH_TOKEN="$CACHIX_KEY"

    # Superproject bundle/installer + integration outputs (submodule-aware).
    super_attrs=(
      ".?submodules=1#package-linux"
      ".?submodules=1#package-portable-tarball"
      ".?submodules=1#package-nsis"
      ".?submodules=1#bundled-app"
      ".?submodules=1#bundled-tui"
    )
    # daemon-app thin-client artifacts + the expensive static-Qt build closures (pushed directly:
    # the installers' runtime closures do NOT carry these build-time Qt stacks).
    app_attrs=(
      "./daemon-app#apk"
      "./daemon-app#wasm"
      "./daemon-app#qt-linux-static"
      "./daemon-app#qt-mingw-static"
      "./daemon-app#qt-android"
      "./daemon-app#qt-wasm"
    )
    # daemon-node cross-built Windows engine workers + the prebuilt llama.cpp they build against.
    # The NSIS bundle copies the llama worker's DLLs into its payload, so the worker derivation
    # itself never lands in package-nsis's runtime closure - push these directly so CI / other
    # machines pull the heavy Windows cross build instead of rebuilding it. (Metal lanes are
    # aarch64-darwin only and are seeded from a mac host, not this Linux recipe.)
    node_attrs=(
      "./daemon-node#daemon-infer-llama-windows"
      "./daemon-node#daemon-infer-mistralrs-windows"
      "./daemon-node#llama-cpp-windows"
    )

    paths=()
    for a in "${super_attrs[@]}" "${app_attrs[@]}" "${node_attrs[@]}"; do
      echo "cache-push: building $a" >&2
      while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done \
        < <(nix build --print-out-paths --no-link "$a")
    done

    # devShell closures (so CI's `nix develop` pulls instead of rebuilding).
    for flake in ./daemon-node ./daemon-app; do
      prof="$(mktemp -u /tmp/daemon-cache-profile.XXXXXX)"
      echo "cache-push: realizing devShell $flake" >&2
      nix develop "$flake" --profile "$prof" --command true
      paths+=("$(readlink -f "$prof")")
      rm -f "$prof"
    done

    echo "cache-push: pushing ${#paths[@]} store path(s) (with closures) to daemon-ai" >&2
    printf '%s\n' "${paths[@]}" | nix run nixpkgs#cachix -- push daemon-ai

# --- versioning -----------------------------------------------------------
# Each repo owns its SemVer in a top-level VERSION file; the build systems enrich it with a git
# build-metadata suffix (daemon-node/crates/contracts/daemon-common/build.rs and
# daemon-app/cmake/Version.cmake). The superproject VERSION is the bundle/product label.

# Print each component's version (node / app / bundle) plus the wire versions for context.
version:
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%-13s %s\n' "bundle:" "$(tr -d '\r\n' < VERSION)"
    printf '%-13s %s\n' "daemon-node:" "$(tr -d '\r\n' < daemon-node/VERSION)"
    printf '%-13s %s\n' "daemon-app:" "$(tr -d '\r\n' < daemon-app/VERSION)"
    wire="$(sed -n 's/.*pub const CURRENT: Self = Self(\([0-9]*\)).*/\1/p' \
      daemon-node/crates/contracts/daemon-common/src/lib.rs | head -n1 || true)"
    mux="$(sed -n 's/.*kWireVersion = \([0-9]*\).*/\1/p' \
      daemon-app/src/core/daemon/node_api_codec.h | head -n1 || true)"
    [ -n "$wire" ] && printf '%-13s %s\n' "wire (api):" "$wire" || true
    [ -n "$mux" ] && printf '%-13s %s\n' "wire (mux):" "$mux" || true

# Gate: each VERSION is strict SemVer, and daemon-node/VERSION matches its Cargo workspace version
# (the one place the base is duplicated). Part of the `lint` umbrella.
check-version:
    #!/usr/bin/env bash
    set -euo pipefail
    status=0
    semver='^[0-9]+\.[0-9]+\.[0-9]+$'
    for f in VERSION daemon-node/VERSION daemon-app/VERSION; do
      v="$(tr -d '\r\n' < "$f")"
      if ! [[ "$v" =~ $semver ]]; then
        echo "check-version: $f is not strict SemVer X.Y.Z (got '$v')" >&2
        status=1
      fi
    done
    node_file="$(tr -d '\r\n' < daemon-node/VERSION)"
    node_cargo="$(sed -n 's/^version = "\(.*\)"/\1/p' daemon-node/Cargo.toml | head -n1)"
    if [ "$node_file" != "$node_cargo" ]; then
      echo "check-version: daemon-node/VERSION ($node_file) != [workspace.package].version ($node_cargo)" >&2
      status=1
    fi
    if [ "$status" -eq 0 ]; then echo "check-version: OK"; fi
    exit "$status"

# Set a repo's version (the only file a human edits): writes <repo>/VERSION and mechanically syncs
# the derived copies the build tools can't read live - daemon-node's Cargo.toml
# [workspace.package].version and daemon-app's packaging/UPDATES.json. daemon-app's CMake reads
# VERSION directly, so it needs no sync. `just check-version` still guards against any drift.
# Usage: `just set-version daemon-node 0.0.2` (or `daemon-app`, or `.` for the superproject bundle).
set-version repo version:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! [[ "{{version}}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "set-version: version must be SemVer X.Y.Z (got '{{version}}')" >&2
      exit 1
    fi
    case "{{repo}}" in
      .|daemon-node|daemon-app) ;;
      *) echo "set-version: repo must be one of: . daemon-node daemon-app (got '{{repo}}')" >&2; exit 1 ;;
    esac
    printf '%s\n' "{{version}}" > "{{repo}}/VERSION"
    echo "set-version: {{repo}}/VERSION -> {{version}}"
    if [ "{{repo}}" = "daemon-node" ]; then
      # Mirror into the workspace package version (the literal Cargo requires; first line-anchored
      # `version =`, i.e. the [workspace.package] one - the deps use `name = { ... }`).
      sed -i '0,/^version = ".*"/s//version = "{{version}}"/' daemon-node/Cargo.toml
      echo "set-version: daemon-node/Cargo.toml [workspace.package].version -> {{version}}"
    elif [ "{{repo}}" = "daemon-app" ]; then
      # Mirror into the desktop updater feed.
      sed -i 's/"latest-version": "[^"]*"/"latest-version": "{{version}}"/' \
        daemon-app/packaging/UPDATES.json
      echo "set-version: daemon-app/packaging/UPDATES.json latest-version -> {{version}}"
    fi
    echo "set-version: done (verify with: just check-version)"

# Cut a release tag from a repo's VERSION file (SemVer + clean-tree + tag==vVERSION + monotonic bump).
# Usage: `just release daemon-node` (or `daemon-app`, or omit for the superproject). DRY_RUN=1 previews.
release repo=".":
    nix develop ./daemon-node --command bash scripts/release.sh {{repo}}

# --- codec contract -------------------------------------------------------

# Prove the generated C codec round-trips real ciborium fixtures (daemon-node).
verify-codec:
    cd daemon-node && nix build ".#checks.{{system}}.verify-codec" -L

# Prove the Rust serde wire format matches the authoritative daemon-api.cddl: representative fixtures
# (+ negative cases) via cddl-cat, then arbitrary values across every variant via proptest.
conformance:
    cd daemon-node && nix develop --command cargo test -p daemon-api --test conformance
    cd daemon-node && nix develop --command cargo test -p daemon-api --features arbitrary --test conformance_proptest

# Fail if daemon-app's vendored codec drifts from the daemon-node contract.
codec-drift:
    nix build ".?submodules=1#checks.{{system}}.codec-drift" -L

# Regenerate the vendored codec into the working tree from the contract.
update-codec:
    nix run ".?submodules=1#update-codec"

# Regenerate the vendored codec, then build everything (the "clean automatic" path).
sync: update-codec build-all

# --- icon pipeline --------------------------------------------------------
# The two source SVGs (daemon-app/packaging/icons/{small,large}.svg) are the only
# hand-edited icon assets; every committed platform format (Linux hicolor PNGs +
# scalable SVG, Windows .ico, macOS .icns, Android mipmaps, iOS asset catalog,
# web favicons, and the app-embedded window/tray PNGs) is generated from them by
# daemon-app's nix/icons.nix. Like the codec, the outputs are checked in so
# packaging never rasterizes at build time.

# Regenerate the committed platform icons into the working tree from the SVGs.
update-icons:
    cd daemon-app && nix run ".#update-icons"

# Gate: committed icons must match what the SVGs regenerate (the icon codec-drift).
icons-drift:
    cd daemon-app && nix build ".#checks.{{system}}.icons-drift" -L

# --- fast dev iteration loop ----------------------------------------------
# Reproduce the `nix run '.?submodules=1#bundled-app'` experience from warm INCREMENTAL dev builds
# instead of the sealed release `nix build`. The bundle wrapper is only a few env vars (DAEMON_BIN,
# DAEMON_INFER__WORKER_BIN, DAEMON_APP_SERVICE_MODE - see flake.nix bundleWithDaemon), so the same
# daemon-service GUI runs from `daemon-node/target/debug` + the warm `daemon-app/build/` tree, with
# edit->run cycles in seconds instead of a full re-derivation. Engine libs (llama/ggml/mtmd .so)
# are kept OFF the GUI process: the daemon is launched via a generated `.dev/daemon-dev` wrapper
# that exports the node devShell's LD_LIBRARY_PATH and execs the debug daemon, so the GUI (built
# against daemon-app's different nixpkgs pin) never inherits them. `.dev/` is gitignored.

# The bundled-app experience from incremental builds (daemon service mode).
dev-run:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$PWD"
    # 1) Node: daemon host + operator CLI (debug, incremental).
    ( cd daemon-node && nix develop --command cargo build -p daemon -p daemon-cli )
    # 2) Worker: daemon-infer with the multimodal llama engine, linked against the prebuilt shared
    #    llama.cpp (now carries libmtmd) - skips cmake, only the cc-built mtp_shim compiles here.
    ( cd daemon-node && nix develop --command cargo build -p daemon-infer --features llama,mtmd,dynamic-link )
    # 3) Wrapper: capture the node devShell's LD_LIBRARY_PATH (llama/ggml/mtmd + vulkan loader + gcc
    #    runtime) and bake it into a small launcher that execs the debug daemon, so those engine
    #    libs live on the daemon/worker processes only - never the GUI.
    node_ldpath="$(cd daemon-node && nix develop --command sh -c 'printf %s "$LD_LIBRARY_PATH"')"
    mkdir -p "$root/.dev"
    printf '#!/usr/bin/env bash\n# Generated by `just dev-run` (.dev/ is gitignored).\nexport LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\nexec "%s/daemon-node/target/debug/daemon" "$@"\n' \
      "$node_ldpath" "$root" > "$root/.dev/daemon-dev"
    chmod +x "$root/.dev/daemon-dev"
    # 4) App: (re)configure + build only the GUI client target from the warm daemon-app tree (Debug
    #    + Ninja + TUI). The configure is idempotent against the existing cache; building just the
    #    `daemon-app` target keeps the loop fast (the default target set also builds every unit-test
    #    executable - minutes of work the dev loop does not need).
    ( cd daemon-app && nix develop --command sh -c 'cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug -DDAEMON_APP_TUI=ON -DDAEMON_APP_QML_DEBUG=OFF -DCMAKE_LINKER_TYPE=MOLD && cmake --build build --target daemon-app' )
    # 5) Launch the GUI in daemon service mode with the bundle env vars, from inside the daemon-app
    #    devShell (which supplies QT_PLUGIN_PATH / QML_IMPORT_PATH). The daemon it spawns is the
    #    .dev wrapper; the worker is the debug daemon-infer.
    export DAEMON_BIN="$root/.dev/daemon-dev"
    export DAEMON_INFER__WORKER_BIN="$root/daemon-node/target/debug/daemon-infer"
    export DAEMON_APP_SERVICE_MODE=daemon
    exec nix develop ./daemon-app --command "$root/daemon-app/build/src/DaemonApp/App/daemon-app"

# Same fast loop, but launch the TUI client instead of the GUI.
dev-run-tui:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$PWD"
    ( cd daemon-node && nix develop --command cargo build -p daemon -p daemon-cli )
    ( cd daemon-node && nix develop --command cargo build -p daemon-infer --features llama,mtmd,dynamic-link )
    node_ldpath="$(cd daemon-node && nix develop --command sh -c 'printf %s "$LD_LIBRARY_PATH"')"
    mkdir -p "$root/.dev"
    printf '#!/usr/bin/env bash\n# Generated by `just dev-run-tui` (.dev/ is gitignored).\nexport LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\nexec "%s/daemon-node/target/debug/daemon" "$@"\n' \
      "$node_ldpath" "$root" > "$root/.dev/daemon-dev"
    chmod +x "$root/.dev/daemon-dev"
    ( cd daemon-app && nix develop --command sh -c 'cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug -DDAEMON_APP_TUI=ON && cmake --build build --target daemon-tui' )
    export DAEMON_BIN="$root/.dev/daemon-dev"
    export DAEMON_INFER__WORKER_BIN="$root/daemon-node/target/debug/daemon-infer"
    export DAEMON_APP_SERVICE_MODE=daemon
    exec nix develop ./daemon-app --command "$root/daemon-app/build/src/tui/daemon-tui"

# Clean-slate user-testing run: reset all local state, then dev-run.
fresh-run: dev-reset dev-run

# --- end-to-end -----------------------------------------------------------

# Run the cross-repo E2E suite against freshly built binaries.
e2e: build-node
    #!/usr/bin/env bash
    set -euo pipefail
    # Build both client targets incrementally from the warm daemon-app tree (one configure builds
    # GUI+TUI) instead of two sealed `nix build`s - matches the dev-run loop and keeps e2e iteration
    # fast. Only the `daemon-app` + `daemon-tui` targets are built (not the default set, which also
    # compiles every unit-test executable). CI does NOT call `just e2e` (it runs its own sealed
    # `nix build` path), so release-artifact coverage is unchanged by this local-only switch.
    ( cd daemon-app && nix develop --command sh -c 'cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug -DDAEMON_APP_TUI=ON && cmake --build build --target daemon-app daemon-tui' )
    export DAEMON_BIN="$PWD/daemon-node/target/debug/daemon"
    export DAEMON_CLI_BIN="$PWD/daemon-node/target/debug/daemon-cli"
    export CLIENT_GUI_BIN="$PWD/daemon-app/build/src/DaemonApp/App/daemon-app"
    export CLIENT_TUI_BIN="$PWD/daemon-app/build/src/tui/daemon-tui"
    # Run the harness with BOTH devShells nested: the app shell provides Qt plugin/QML paths so the
    # unwrapped dev client binaries launch, and the node shell provides the cargo toolchain that
    # compiles + runs the system-tests. --test-threads=1 keeps daemon/socket-owning scenarios serial.
    cd system-tests && nix develop ../daemon-app --command nix develop ../daemon-node --command cargo test -- --test-threads=1

# Run only the protocol-trace scenarios (daemon + CLI; no client binaries needed).
e2e-protocol: build-node
    #!/usr/bin/env bash
    set -euo pipefail
    export DAEMON_BIN="$PWD/daemon-node/target/debug/daemon"
    export DAEMON_CLI_BIN="$PWD/daemon-node/target/debug/daemon-cli"
    cd system-tests && nix develop ../daemon-node --command cargo test --test protocol_trace -- --test-threads=1

# --- wasm browser smoke / e2e ---------------------------------------------
# Extra gates for wasm-touching changes (src/core/platform/wasm_*, the wasm shell, IDBFS/settings
# persistence, browser file/clipboard flows). The browser comes from the daemon-app #wasm devShell's
# bundled headless chromium (the host chromium is often a firejail wrapper that aborts under
# --headless), surfaced to the harness via $CHROMIUM.

# Boot-smoke the wasm bundle over CDP: assert the boot marker + WebGL2 renderer verdict.
wasm-smoke: build-wasm
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop ./daemon-app#wasm --command \
        bash daemon-app/scripts/wasm-boot-smoke.sh \
            "$PWD/result-app-wasm/share/daemon-app/wasm"

# Reload-survival browser e2e (scripts/wasm-boot-smoke.py --scenario reload): drive first-load ->
# Page.reload and assert browser-origin state survives. `base` proves the reload + origin-storage
# (localStorage + IDBFS) substrate with no daemon; `strict` self-boots a mock-provider daemon
# serving a patched bundle copy and asserts the pinned sentinels (DAEMON_APP_AUTH resumed,
# DAEMON_APP_CACHE rows>0 pre-fetch, DAEMON_APP_FIRSTRUN done). --seed-session drives daemon-cli to
# create a durable session before load 1 so the client's first sync warms the cache -> IDBFS, making
# load2's pre-fetch count non-vacuously >0. Set E2E_WEB_STRICT=0 to run base only (e.g. a host where
# headless chromium boots but the node-side reload timing is unreliable; strict belongs in CI).
#
# Reload-survival browser e2e: base substrate + (default) strict sentinels with node-side seeding.
e2e-web: build-node build-wasm
    #!/usr/bin/env bash
    set -euo pipefail
    DAEMON_BIN="$PWD/daemon-node/target/debug/daemon"
    DAEMON_CLI_BIN="$PWD/daemon-node/target/debug/daemon-cli"
    WASM_DIR="$PWD/result-app-wasm/share/daemon-app/wasm"
    # Base mode (proves reload + browser-storage survival, no daemon).
    nix develop ./daemon-app#wasm --command \
        python3 daemon-app/scripts/wasm-boot-smoke.py \
            --scenario reload --mode base "$WASM_DIR"
    # Strict mode (full re-auth / warm-cache / first-run sentinels + node-side seeding).
    if [ "${E2E_WEB_STRICT:-1}" = "1" ]; then
        nix develop ./daemon-app#wasm --command \
            python3 daemon-app/scripts/wasm-boot-smoke.py \
                --scenario reload --mode strict \
                --daemon-bin "$DAEMON_BIN" --wasm-dir "$WASM_DIR" \
                --seed-session --daemon-cli-bin "$DAEMON_CLI_BIN" \
                --login e2e:e2e-passphrase
    fi

# --- dev-state reset --------------------------------------------------------

# Reset all local daemon/app state so a verification run starts from a clean slate: stop the
# app-managed daemon (pidfile-first; by-exe only for daemon-node builds - never a blanket pkill),
# then remove the managed socket + pidfile, the app's QSettings/config + data + cache dirs, the
# node's default data dir (sqlite store + auth db), and legacy $TMPDIR daemon-store leftovers.
# Idempotent (exit 0 when there is nothing to clean). DRY_RUN=1 previews without killing/removing.
#
# Installed models are kept by default (they are big and re-downloadable). Opt in with:
#   DEV_RESET_MODELS=1    also remove the daemon-owned model registry (daemon-catalog.json) and
#                         quantize output (daemon-quantized/) from the hub cache the daemon
#                         resolves, so the daemon reports a truly fresh (empty) installed catalog.
#   DEV_RESET_MODELS=all  additionally remove the models--*/ artifact trees from that hub cache.
#                         CAREFUL: the default hub (~/.cache/huggingface/hub) is shared with other
#                         HF tooling - `all` deletes THEIR downloads too. The resolution mirrors
#                         the daemon's (daemon-models cache.rs): DAEMON_MODELS__CACHE_DIR, else
#                         HF_HUB_CACHE, else HF_HOME/hub, else XDG_CACHE_HOME/huggingface/hub,
#                         else ~/.cache/huggingface/hub.
dev-reset:
    #!/usr/bin/env bash
    set -euo pipefail
    dry="${DRY_RUN:-0}"
    note() { echo "dev-reset: $*"; }
    tmp="${TMPDIR:-/tmp}"
    cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
    data="${XDG_DATA_HOME:-$HOME/.local/share}"
    cache="${XDG_CACHE_HOME:-$HOME/.cache}"
    # Managed-socket dirs: the app default (RuntimeLocation, then its TempLocation fallback - see
    # isettings_store.h defaultManagedSocketPath) plus the dir of any env-override socket.
    sock_dirs=()
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then sock_dirs+=("$XDG_RUNTIME_DIR/daemon"); fi
    sock_dirs+=("$tmp/daemon")
    socks=()
    for d in "${sock_dirs[@]}"; do socks+=("$d/daemon.sock"); done
    for s in "${DAEMON_APP_SOCKET:-}" "${DAEMON_SOCKET_PATH:-}"; do
      if [ -n "$s" ]; then socks+=("$s"); sock_dirs+=("$(dirname "$s")"); fi
    done
    # 1) Stop daemons we own. Pidfile-first: local_daemon_launcher.cpp records every managed spawn
    #    in <socket dir>/daemon.pid. A pid is signalled only when its comm is exactly `daemon`.
    term() {
      local pid="$1" why="$2" want="${3:-daemon}" comm
      comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
      if [ "$comm" != "$want" ]; then
        if [ -n "$comm" ]; then note "skip pid $pid ($why): comm '$comm' is not '$want'"; fi
        return 0
      fi
      if [ "$dry" = "1" ]; then note "would stop pid $pid ($why)"; return 0; fi
      note "stopping pid $pid ($why)"
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 50); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
      done
      note "pid $pid ignored SIGTERM; sending SIGKILL"
      kill -9 "$pid" 2>/dev/null || true
    }
    for d in "${sock_dirs[@]}"; do
      pf="$d/daemon.pid"
      [ -f "$pf" ] || continue
      pid="$(tr -cd '0-9' < "$pf" || true)"
      if [ -n "$pid" ] && [ "$pid" -gt 1 ]; then term "$pid" "pidfile $pf"; fi
    done
    # Stragglers from pre-pidfile builds: same-user processes named `daemon` whose executable is a
    # daemon-node build we spawned (a bundled /nix/store/.../bin/daemon or this checkout's build
    # outputs). Anything else named `daemon` is left alone.
    for pid in $(pgrep -x -u "$(id -u)" daemon 2>/dev/null || true); do
      exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
      # A non-dumpable process hides its exe link even from the owning user; argv[0] (set to the
      # absolute binary path by the launcher / a plain spawn) still names the binary.
      if [ -z "$exe" ]; then
        exe="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -n 1 || true)"
      fi
      case "$exe" in
        /nix/store/*/bin/daemon | "$PWD"/daemon-node/target/*/daemon | "$PWD"/result*/bin/daemon)
          term "$pid" "exe $exe" ;;
        *)
          if [ -n "$exe" ]; then note "leaving pid $pid alone (exe $exe is not a daemon-node build)"; fi ;;
      esac
    done
    # Orphaned inference workers: a crashed daemon can leave its `daemon-infer` child running. Same
    # exe-path whitelist as the daemon sweep (this checkout's target/* build, a bundled store path,
    # or a result*/ out-link); anything else named daemon-infer is left alone.
    for pid in $(pgrep -x -u "$(id -u)" daemon-infer 2>/dev/null || true); do
      exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
      if [ -z "$exe" ]; then
        exe="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -n 1 || true)"
      fi
      case "$exe" in
        /nix/store/*/bin/daemon-infer | "$PWD"/daemon-node/target/*/daemon-infer | "$PWD"/result*/bin/daemon-infer)
          term "$pid" "exe $exe" daemon-infer ;;
        *)
          if [ -n "$exe" ]; then note "leaving pid $pid alone (exe $exe is not a daemon-node build)"; fi ;;
      esac
    done
    # 2) Remove on-disk state, printing each existing path as it goes.
    remove() {
      local p
      for p in "$@"; do
        if [ -e "$p" ] || [ -L "$p" ]; then
          if [ "$dry" = "1" ]; then note "would remove $p"; else note "removing $p"; rm -rf -- "$p"; fi
        fi
      done
    }
    remove "${socks[@]}"
    for d in "${sock_dirs[@]}"; do remove "$d/daemon.pid"; done
    remove "$cfg/daemon-app"           # QSettings: daemon-app.conf + daemon-tui.conf (first-run flag, conn target)
    remove "$data/daemon-app"          # AppDataLocation: managed-daemon data dir, daemon_cache.db, mock/
    remove "$cache/daemon-app"         # CacheLocation: image cache, qmlcache
    remove "$data/daemon"              # node default data dir: daemon-store.sqlite, auth.sqlite, blobs/, workspaces/
    remove ".dev"                      # dev-run's generated daemon launcher dir (.dev/daemon-dev)
    remove "$tmp"/daemon-store.sqlite* # legacy pre-hardening store default (+ -wal/-shm)
    remove "$tmp/daemon-api.sock"      # node standalone default socket
    if [ -n "${DAEMON_STORE_PATH:-}" ]; then
      remove "$DAEMON_STORE_PATH" "$DAEMON_STORE_PATH-wal" "$DAEMON_STORE_PATH-shm"
    fi
    # 3) Opt-in model-state reset (see the recipe doc above). Resolves the SAME hub cache dir the
    #    daemon does, and by default touches only the daemon-owned files inside it.
    models="${DEV_RESET_MODELS:-0}"
    if [ "$models" = "1" ] || [ "$models" = "all" ]; then
      if [ -n "${DAEMON_MODELS__CACHE_DIR:-}" ]; then hub="$DAEMON_MODELS__CACHE_DIR";
      elif [ -n "${HF_HUB_CACHE:-}" ]; then hub="$HF_HUB_CACHE";
      elif [ -n "${HF_HOME:-}" ]; then hub="$HF_HOME/hub";
      else hub="$cache/huggingface/hub"; fi
      note "model reset targets hub cache: $hub"
      remove "$hub/daemon-catalog.json" "$hub/daemon-catalog.json.tmp" "$hub/daemon-quantized"
      if [ "$models" = "all" ]; then
        # The artifact trees are the standard shared HF layout - this also removes non-daemon
        # downloads living in the same hub (documented above; that is what `all` means).
        for m in "$hub"/models--*; do remove "$m"; done
      fi
    fi
    if [ "$dry" != "1" ]; then
      for d in "${sock_dirs[@]}"; do rmdir "$d" 2>/dev/null || true; done
    fi
    note "clean"

# --- lint / format gates --------------------------------------------------
# Tools come from the per-repo Nix devShells (`nix develop`), so these run the same
# pinned versions everywhere. `lint` is the umbrella gate; the sub-recipes run a single
# language. The Rust gate uses default features to mirror the workspace CI gate (the engine
# lanes - llama/mistralrs/hyperon - are deliberately separate outputs that need native libs).

# Run every fast static gate (version consistency + Rust + C++/QML + secrets + spelling + schema).
lint: check-version lint-rust lint-cpp secrets spell check-schema check-config-reference

# On-disk schema-drift gate: each rusqlite store's live schema must match its committed golden
# (the on-disk analogue of `codec-drift`). A DDL change must add a migration AND refresh the golden
# (`DAEMON_UPDATE_SCHEMA=1 cargo test … schema_matches_golden`).
check-schema:
    cd daemon-node && nix develop --command cargo test -p daemon-store --features sqlite -p daemon-context-lcm -p daemon-mnemosyne -- schema_matches_golden migration_ladder

# Doc-drift gate: the committed docs/config-reference.md must match the generator
# (`daemon config reference`). The generator (NodeConfig::default) is the single source of truth;
# this replaces the former compile-time include_str! test (which broke the sandboxed crate build).
# Regenerate with `just update-config-reference`.
check-config-reference:
    cd daemon-node && nix develop --command bash -euo pipefail -c '\
      diff -u docs/config-reference.md <(cargo run -q -p daemon --bin daemon -- config reference) \
      || { echo "docs/config-reference.md is stale; run: just update-config-reference" >&2; exit 1; }'

# Regenerate the committed config reference from the generator (the single source of truth).
update-config-reference:
    cd daemon-node && nix develop --command bash -euo pipefail -c '\
      cargo run -q -p daemon --bin daemon -- config reference > docs/config-reference.md'

# Rust: rustfmt check + clippy with warnings denied (the de-facto lint gate).
lint-rust:
    cd daemon-node && nix develop --command bash -euo pipefail -c '\
      cargo fmt --check && \
      cargo clippy --workspace --all-targets -- -D warnings'

# Rust dependency policy: advisories (RustSec) + licenses + bans + sources.
deny:
    cd daemon-node && nix develop --command cargo deny check

# A build runs first so Qt's generated moc/qml headers exist for clang-tidy.
# C++/QML: clang-format check + clang-tidy (compile_commands) + qmllint.
lint-cpp:
    #!/usr/bin/env bash
    set -euo pipefail
    cd daemon-app
    nix develop --command bash -euo pipefail -c '
      # <DEP>_SOURCE_DIR vars are exported by the devShell; CMake reads them from the env.
      cmake -B build-lint -G Ninja -DBUILD_TESTING=ON -DDAEMON_APP_TUI=ON >/dev/null
      cmake --build build-lint >/dev/null
      echo "== clang-format =="
      git ls-files "src/*.cpp" "src/*.h" "tests/*.cpp" "tests/*.h" \
        | xargs clang-format --dry-run --Werror
      echo "== clang-tidy =="
      # clang-tools ships clang-tidy but not the run-clang-tidy wrapper; drive it per-TU in parallel.
      git ls-files "src/*.cpp" | xargs -r -P "$(nproc)" -n1 clang-tidy -p build-lint --quiet
      echo "== qmllint =="
      # The aggregate all_qmllint target is broken under Qt 6.11 + Ninja (an unexpanded $<IF:...>
      # generator expression - a Qt/CMake bug, not a QML defect). Drive qmllint per module via the
      # generated *_module.rsp response files instead; each lints one QML module by name. qmllint
      # warnings are exit 0 (surfaced, non-fatal); only hard errors fail the gate.
      qmllint_status=0
      while IFS= read -r -d "" rsp; do
        qmllint @"$rsp" || qmllint_status=1
      done < <(find build-lint -path "*/.rcc/qmllint/*_module.rsp" -print0)
      [ "$qmllint_status" -eq 0 ]
    '

# Auto-fix what is mechanically fixable (rustfmt + clang-format + gersemi). Never run in a gate.
fmt-fix:
    #!/usr/bin/env bash
    set -euo pipefail
    cd daemon-node && nix develop --command cargo fmt
    cd ../daemon-app && nix develop --command bash -euo pipefail -c '
      git ls-files "src/*.cpp" "src/*.h" "tests/*.cpp" "tests/*.h" | xargs clang-format -i
      git ls-files "*/CMakeLists.txt" "CMakeLists.txt" "cmake/*.cmake" | xargs gersemi -i
    '

# --- repo hygiene ---------------------------------------------------------

# Scan the whole superproject (incl. submodules) for committed secrets.
secrets:
    nix develop ./daemon-node --command gitleaks detect --no-banner --redact -v

# Spell-check sources/docs (low false-positive). Tune via a typos config if needed.
spell:
    nix develop ./daemon-node --command typos

# REUSE/SPDX licensing compliance across the superproject + both submodules.
# Uses the pinned `reuse` from nixpkgs. The superproject and daemon-app are
# compliant; daemon-node has a known remaining set (bundled third-party skill
# reference docs under crates/skills/.../research/) still pending provenance
# review before it can be marked compliant.
reuse:
    #!/usr/bin/env bash
    set -uo pipefail
    status=0
    for repo in . daemon-node daemon-app; do
      echo "==== reuse lint: $repo ===="
      (cd "$repo" && nix run nixpkgs#reuse -- lint) || status=1
    done
    exit "$status"

# Copy/paste duplication report across both source trees (jscpd via npx; first run fetches it).
dup:
    nix develop ./daemon-node --command npx --yes jscpd@4 \
      --pattern "daemon-node/crates/**/*.rs,daemon-node/tools/**/*.rs,daemon-app/src/**/*.{cpp,h,qml}" \
      --ignore "**/target/**,**/build*/**,**/research/**,**/generated/**,**/vendor/**" \
      --min-tokens 60 --reporters consoleFull

# --- dead code / unused deps (occasional cleanup) -------------------------

# Advisory only - results are candidates, not auto-deletions (Qt slots / QML-invoked / FFI
# exports / feature-gated code commonly show up as false positives).
# Cleanup triage: unused Rust deps + unused C++ functions + duplication + unused includes.
audit-cleanup:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "==== cargo-machete (unused Rust dependencies) ===="
    (cd daemon-node && nix develop --command cargo machete) || true
    echo "==== cppcheck (whole-program unused functions) ===="
    cd daemon-app
    nix develop --command bash -uo pipefail -c '
      cmake -B build-lint -G Ninja -DBUILD_TESTING=ON -DDAEMON_APP_TUI=ON >/dev/null
      # compile_commands.json includes vendored deps (microtex/md4qt/ksyntaxhighlighting built via
      # add_subdirectory); suppress findings in the Nix store so only our src/ is reported.
      cppcheck --project=build-lint/compile_commands.json \
        --enable=unusedFunction --inline-suppr --quiet \
        --suppress="*:*/nix/store/*" -i "$PWD/build-lint" 2>&1 | grep -v "checkers" || true
      echo "==== clang-tidy include-cleaner (unused #includes) ===="
      cmake --build build-lint >/dev/null
      git ls-files "src/*.cpp" | xargs -r -P "$(nproc)" -n1 \
        clang-tidy -p build-lint --quiet -checks="-*,misc-include-cleaner" || true
    '
    cd .. && just dup || true

# --- deeper correctness (comprehensive, occasional) -----------------------

# Check every feature combination compiles (the engine/feature gates agents often miss).
hack:
    cd daemon-node && nix develop --command cargo hack check --workspace --feature-powerset --depth 2

# Mutation testing: find code where injected bugs don't fail any test (validates test strength).
# Scope to one crate with `just mutants daemon-protocol`; defaults to the whole workspace.
mutants package="":
    cd daemon-node && nix develop --command bash -euo pipefail -c '\
      if [ -n "{{package}}" ]; then cargo mutants -p {{package}}; else cargo mutants; fi'

# Source-based coverage (HTML report under daemon-node/target/llvm-cov).
coverage:
    cd daemon-node && nix develop --command cargo llvm-cov --workspace --html

# Scoped to the crates with `unsafe` so the run stays tractable.
# Miri: detect UB over the FFI / codec unsafe surface (nightly devShell).
miri:
    cd daemon-node && nix develop .#nightly --command bash -euo pipefail -c '\
      cargo miri test -p daemon-core-ffi -p daemon-ffi'

# Pass a target name + optional seconds, e.g. `just fuzz decode_client 60`.
# Fuzz the wire codec / protocol decode paths (nightly devShell + cargo-fuzz).
fuzz target="" secs="60":
    #!/usr/bin/env bash
    set -euo pipefail
    cd daemon-node
    if [ -z "{{target}}" ]; then
      nix develop .#nightly --command cargo fuzz list || echo "no fuzz targets yet - add one under daemon-node/fuzz/"
    else
      nix develop .#nightly --command cargo fuzz run {{target}} -- -max_total_time={{secs}}
    fi

# AddressSanitizer + UBSan build of the C++ test suite, run headless.
sanitize:
    #!/usr/bin/env bash
    set -euo pipefail
    cd daemon-app
    nix develop --command bash -euo pipefail -c '
      cmake -B build-asan -G Ninja -DBUILD_TESTING=ON -DDAEMON_APP_TUI=ON \
        -DCMAKE_BUILD_TYPE=Debug \
        -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g" \
        -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined" >/dev/null
      cmake --build build-asan
      QT_QPA_PLATFORM=offscreen ASAN_OPTIONS=detect_leaks=0 \
        ctest --test-dir build-asan --output-on-failure
    '

# Shells into the pinned Nix devShells so hook tool versions match the gates.
# Install the fast pre-commit hook (gitleaks + typos + format) into all three repos.
install-hooks:
    #!/usr/bin/env bash
    set -euo pipefail
    hook="$PWD/scripts/pre-commit.sh"
    chmod +x "$hook"
    for repo in . daemon-node daemon-app; do
      dir=$(git -C "$repo" rev-parse --git-path hooks 2>/dev/null) || { echo "skip $repo (not a git repo)"; continue; }
      ln -sf "$hook" "$repo/$dir/pre-commit"
      echo "installed pre-commit hook -> $repo/$dir/pre-commit"
    done
    # Superproject-only signed-commit gate: pre-push cryptographically verifies every pushed
    # commit is GPG-signed (see scripts/pre-push.sh). The children sign by convention only.
    pushhook="$PWD/scripts/pre-push.sh"
    chmod +x "$pushhook"
    superdir=$(git rev-parse --git-path hooks)
    ln -sf "$pushhook" "$superdir/pre-push"
    echo "installed pre-push signed-commit gate -> $superdir/pre-push"

# --- code review / tech-debt tooling (opt-in `review` shell) --------------
# CodeScene (cs / cs-mcp) + mrva (+ codeql) live in the unfree-gated `.#review` devShell, which
# sources .env for CS_ACCESS_TOKEN / GITHUB_TOKEN. None of this is on the free `default` path.

# Launch Cursor inside the review shell so cs / cs-mcp / mrva / codeql + .env tokens are on PATH.
cursor:
    nix develop .#review --command cursor .

# Local Code Health of a file, lint-style (CodeScene CLI). Usage: `just code-health daemon-node/crates/node/src/main.rs`.
code-health file:
    nix develop .#review --command cs check {{file}}

# Dump CodeScene Cloud projects as JSON (worst hotspot health first) so you can find a project id.
cs-projects:
    nix develop .#review --command bash -euo pipefail -c '\
      : "${CS_ACCESS_TOKEN:?set CS_ACCESS_TOKEN in .env}"; \
      curl -fsS -H "Accept: application/json" -H "Authorization: Bearer ${CS_ACCESS_TOKEN}" \
        "${CS_API:-https://api.codescene.io}/v2/projects?order_by=analysis.hotspot_code_health.now" | jq .'

# Export a project's latest hotspot/code-health ranking to codescene-hotspots-<id>.json (agent-readable).
# Usage: `just hotspots <project-id>` (get the id from `just cs-projects`).
hotspots project:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#review --command bash -euo pipefail -c '
      : "${CS_ACCESS_TOKEN:?set CS_ACCESS_TOKEN in .env}"
      base="${CS_API:-https://api.codescene.io}"
      auth=(-H "Accept: application/json" -H "Authorization: Bearer ${CS_ACCESS_TOKEN}")
      analysis=$(curl -fsS "${auth[@]}" "$base/v2/projects/{{project}}/analyses" | jq -r ".analyses[0].id")
      curl -fsS "${auth[@]}" "$base/v2/projects/{{project}}/analyses/$analysis/files?order_by=change_frequency" \
        > "codescene-hotspots-{{project}}.json"
      echo "wrote codescene-hotspots-{{project}}.json (analysis $analysis)"
    '

# Pull the prebuilt CodeQL databases (needs GITHUB_TOKEN in .env). The codeql.yml workflow lives in
# the superproject and analyzes both submodules via source-root, so GitHub publishes BOTH language
# databases under daemon-ai/daemon (not the submodule repos). c-cpp only appears once that lane of
# codeql.yml passes; until then only the rust database is downloaded.
mrva-pull:
    nix develop .#review --command bash -euo pipefail -c '\
      mkdir -p .mrva; \
      mrva download --language rust .mrva repo --owner daemon-ai --repository daemon; \
      mrva download --language cpp  .mrva repo --owner daemon-ai --repository daemon \
        || echo "note: no c-cpp CodeQL database yet (the codeql.yml analyze (c-cpp) lane is failing)"'

# Run a CodeQL query pack across the pulled databases and pretty-print findings.
# Usage: `just mrva-scan path/to/codeql-queries/rust/src` (clone github.com/trailofbits/codeql-queries).
mrva-scan queries:
    nix develop .#review --command bash -euo pipefail -c '\
      mrva analyze .mrva {{queries}} -- --rerun --threads=0; \
      mrva pprint .mrva'
