{
  description = "daemon superproject: cross-repo codec sync + end-to-end integration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # The two children, consumed ONLY by the integration `bundled-*` outputs below (the daemon
    # binary shipped alongside the client so managed local-daemon spawn finds it - user story
    # CON-1b). These are path inputs into the submodules; evaluate with `?submodules=1` so their
    # working trees are populated. The codec outputs above do not use them, keeping codec-drift /
    # update-codec independent of the children's build closures.
    daemon-node.url = "path:./daemon-node";
    daemon-app.url = "path:./daemon-app";
  };

  # NOTE: the daemon-node / daemon-app submodule contents are gitlinks, so this flake must be
  # evaluated with submodule visibility, e.g. `nix build '.?submodules=1#daemon-zcbor-codec'`.
  # The justfile wraps the common commands so callers don't have to remember the flag.
  #
  # This flake owns only the cross-cutting concern (codec sync). The children keep their own flakes
  # as the source of truth for their builds (daemon-node: `.#daemon` / `.#daemon-cli`; daemon-app:
  # `.#default` / `.#tui`); the justfile + CI build them directly. We deliberately do NOT import the
  # child flakes as path inputs here - that would force `?submodules=1` onto every passthrough build
  # and couple this flake to both children's full input closures.
  outputs =
    { self, nixpkgs, flake-utils, daemon-node, daemon-app }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;

        # Bundle/product version: the SemVer base lives in `./VERSION` (the human label over the
        # submodule gitlinks, which pin the exact child commits). The build-metadata id is derived
        # from the superproject source revision, retaining the off-tag / dirty marker like phosphor.
        # Stamped into the bundle wrappers as DAEMON_BUNDLE_VERSION.
        baseVersion = lib.strings.trim (builtins.readFile ./VERSION);
        buildId =
          if self ? shortRev then
            "g${self.shortRev}"
          else if self ? dirtyShortRev then
            "g${lib.removeSuffix "-dirty" self.dirtyShortRev}.dirty"
          else
            "nar${builtins.substring 0 8 (lib.removePrefix "sha256-" (self.narHash or "sha256-unknown"))}";
        bundleVersion = "${baseVersion}+${buildId}";

        # --- opt-in code-review / tech-debt tooling (the `review` devShell) ---------------------
        # Unfree allowance scoped to exactly these names, so the free default / codec / bundle
        # outputs (which use `pkgs` above) never evaluate an unfree package - a free-only
        # contributor's `nix develop` / `nix build` / `nix flake check` is never blocked - while the
        # licence-gated review tooling stays reproducible without any per-dev NIXPKGS_ALLOW_UNFREE.
        pkgsUnfree = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate =
            p: builtins.elem (lib.getName p) [ "codeql" "codescene-cli" "codescene-mcp" ];
        };

        # Nix system -> CodeScene / cs-mcp release artifact platform suffix.
        csPlatforms = {
          x86_64-linux = "linux-amd64";
          aarch64-linux = "linux-aarch64";
          x86_64-darwin = "macos-amd64";
          aarch64-darwin = "macos-aarch64";
        };
        csPlat = csPlatforms.${system} or (throw "review tooling is unsupported on ${system}");

        # CodeScene CLI (`cs`): a GraalVM native image. Only the `-latest` artifact is publicly
        # fetchable (the versioned URLs are access-gated), so it is pinned by content hash; a
        # CodeScene release that moves `latest` trips the hash and forces a deliberate refresh
        # (re-run `nix store prefetch-file` for the four `cs-<plat>-latest.zip` URLs).
        codescene-cli =
          let
            hashes = {
              linux-amd64 = "sha256-If2dVbp1Y3/lu7Id8eqhCqGse2kOI1uqBW3yX7lgGz0=";
              linux-aarch64 = "sha256-FejzCpRuykwHstcKnaYgONQB24D+LPxEW99IEreMhzo=";
              macos-amd64 = "sha256-BOwHqIZvoIa28zzWd0G086dolJjq3SfhqwwdinA6eqQ=";
              macos-aarch64 = "sha256-xh0xV03Wl7N6YUudMUYC5XtovDJf+/y4AkOYGnM+JXU=";
            };
          in
          pkgsUnfree.stdenv.mkDerivation {
            pname = "codescene-cli";
            version = "latest-2026-06-29";
            src = pkgs.fetchurl {
              url = "https://downloads.codescene.io/enterprise/cli/cs-${csPlat}-latest.zip";
              hash = hashes.${csPlat};
            };
            nativeBuildInputs = [ pkgs.unzip ] ++ lib.optional pkgs.stdenv.isLinux pkgs.autoPatchelfHook;
            buildInputs = lib.optionals pkgs.stdenv.isLinux [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];
            sourceRoot = ".";
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              install -Dm755 cs "$out/bin/cs"
              runHook postInstall
            '';
            meta = {
              description = "CodeScene CLI (cs): local Code Health / delta analysis";
              homepage = "https://codescene.io/docs/cli/index.html";
              license = lib.licenses.unfree;
              mainProgram = "cs";
              platforms = builtins.attrNames csPlatforms;
            };
          };

        # CodeScene MCP server (`cs-mcp`, Rust), pinned to a tagged GitHub release. Exposes Code
        # Health / hotspots / tech-debt to MCP clients (Cursor) via the subscription PAT.
        codescene-mcp =
          let
            version = "1.3.6";
            hashes = {
              linux-amd64 = "sha256-R+ntJwZcrb7cFeNZCAsSXmqpdbUuvnHWxgCeZjsqyWA=";
              linux-aarch64 = "sha256-Zun2LSvsj+gZxB9ovBIgToEF/xToMab/0FxAExsWwsg=";
              macos-amd64 = "sha256-pcRo0RvcZ1tid27u01l52IXgzZSYPKvkDNCqI6r5/q8=";
              macos-aarch64 = "sha256-GEEy8KU9dyqvov5ZBCNgORGzHGEa4kGvtj7wZVZ5jiY=";
            };
          in
          pkgsUnfree.stdenv.mkDerivation {
            pname = "codescene-mcp";
            inherit version;
            src = pkgs.fetchurl {
              url = "https://github.com/codescene-oss/codescene-mcp-server/releases/download/MCP-${version}/cs-mcp-${csPlat}.zip";
              hash = hashes.${csPlat};
            };
            nativeBuildInputs = [ pkgs.unzip ] ++ lib.optional pkgs.stdenv.isLinux pkgs.autoPatchelfHook;
            buildInputs = lib.optionals pkgs.stdenv.isLinux [ pkgs.stdenv.cc.cc.lib pkgs.openssl pkgs.zlib ];
            sourceRoot = ".";
            dontConfigure = true;
            dontBuild = true;
            # The zip ships the binary platform-suffixed (e.g. cs-mcp-linux-amd64) next to detached
            # checksum/signature files; install just the executable as `cs-mcp`.
            installPhase = ''
              runHook preInstall
              install -Dm755 "cs-mcp-${csPlat}" "$out/bin/cs-mcp"
              runHook postInstall
            '';
            meta = {
              description = "CodeScene MCP server (cs-mcp): Code Health insights for AI assistants";
              homepage = "https://github.com/codescene-oss/codescene-mcp-server";
              license = lib.licenses.unfree;
              mainProgram = "cs-mcp";
              platforms = builtins.attrNames csPlatforms;
            };
          };

        # mrva: terminal-first CodeQL multi-repo variant analysis (free, AGPL-3.0). `mrva analyze`
        # shells out to the `codeql` CLI, which sits alongside it in the `review` shell.
        mrva = pkgs.python3Packages.buildPythonApplication rec {
          pname = "mrva";
          version = "0.5.0";
          pyproject = true;
          src = pkgs.fetchPypi {
            inherit pname version;
            hash = "sha256-IWsUcUFAk0lUHDMlPj+wssONUIU+Xcq9zNeVeJ5h9Ug=";
          };
          build-system = [ pkgs.python3Packages.poetry-core ];
          dependencies = with pkgs.python3Packages; [ httpx jinja2 ];
          pythonImportsCheck = [ "mrva" ];
          meta = {
            description = "Terminal-first CodeQL multi-repo variant analysis";
            homepage = "https://github.com/trailofbits/mrva";
            license = lib.licenses.agpl3Plus;
            mainProgram = "mrva";
          };
        };

        # The built children for the integration bundles.
        daemonBin = daemon-node.packages.${system}.daemon;
        # The local-inference worker, built WITH the llama engine (the daemon-node default build is
        # a stub worker with no engine at all — a bundle shipping that could download models but
        # never run one). The daemon spawns it per session for llama.cpp profiles.
        daemonInferLlama = daemon-node.packages.${system}.daemon-infer-llama;
        guiApp = daemon-app.packages.${system}.default;
        tuiApp = daemon-app.packages.${system}.tui;

        # Wrap a client so it ships with the daemon host binary: set DAEMON_BIN by default (the
        # LocalDaemonLauncher's first env-based discovery step) so a packaged install can spawn a
        # local daemon out of the box, while a user/operator override of DAEMON_BIN still wins.
        #
        # The bundle is the real product, so it also defaults to ServiceMode::Daemon (real
        # connection + sessions + accounts + models + profiles + chat over the node). Bare dev
        # builds and the test harnesses keep the Mock default unless they opt in explicitly, so
        # in-repo offscreen-render / unit coverage is unaffected. A user override still wins.
        #
        # DAEMON_INFER__WORKER_BIN points the spawned daemon at the co-packaged llama-enabled
        # daemon-infer (the daemon's own next-to-exe discovery cannot work here: DAEMON_BIN names
        # the daemon package's store path, which contains no worker). The env layer wins over the
        # config default, and an operator override of the variable still wins over ours.
        bundleWithDaemon =
          { app, name, mainProgram }:
          pkgs.symlinkJoin {
            inherit name;
            paths = [ app daemonBin daemonInferLlama ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              for client in daemon-app daemon-tui; do
                if [ -e "$out/bin/$client" ]; then
                  wrapProgram "$out/bin/$client" \
                    --set-default DAEMON_BIN "${daemonBin}/bin/daemon" \
                    --set-default DAEMON_INFER__WORKER_BIN "${daemonInferLlama}/bin/daemon-infer" \
                    --set-default DAEMON_APP_SERVICE_MODE "daemon" \
                    --set-default DAEMON_BUNDLE_VERSION "${bundleVersion}"
                fi
              done
            '';
            # Let `nix run` resolve the client binary (the derivation name differs from it).
            meta.mainProgram = mainProgram;
          };

        bundledApp = bundleWithDaemon {
          app = guiApp;
          name = "daemon-app-bundled";
          mainProgram = "daemon-app";
        };
        bundledTui = bundleWithDaemon {
          app = tuiApp;
          name = "daemon-tui-bundled";
          mainProgram = "daemon-tui";
        };

        # --- hosted-node image (see docs/hosted-node-image.md) ----------------------------------
        # The daemon-node backend serving its own Qt WebAssembly GUI on ONE origin (static bundle +
        # authenticated CBOR-mux WebSocket on /ws, one listener), packaged as the OCI image a
        # microVM-based hosting provider ingests (hosted-nodes spec D4/§8.1: Fly Machines /
        # Firecracker take an OCI registry ref; `node_versions.image_ref` pins its digest).
        # Run locally:
        #   podman load -i result-image
        #   podman run -d -p 8080:8080 -v hosted-node-data:/data \
        #     -e DAEMON_ADMIN_USERNAME=operator -e DAEMON_ADMIN_PASSWORD=... \
        #     localhost/daemon-hosted-node:<tag>       # then open http://127.0.0.1:8080/
        #
        # The wasm bundle already ships .br/.gz siblings (daemon-app's postInstall; the web front
        # scans them at boot and negotiates Accept-Encoding), so this repack's only job is
        # `unsafeDiscardReferences`: daemon-app.wasm embeds the qtbase-wasm store path as a dead
        # string constant (a compiled-in Qt prefix), which would otherwise chain the multi-GiB
        # Qt-for-WASM *build* closure into the image (measured: 1.7 GB / 97 layers with the
        # reference, ~0.1 GB / 16 layers without). The artifact is served byte-identical to
        # browsers (which have no /nix/store), so the reference is provably unused at runtime.
        wasmBundle = daemon-app.packages.${system}.wasm;
        webRootDir = "share/daemon-app/wasm";
        webBundle =
          pkgs.runCommand "daemon-web-root"
            {
              __structuredAttrs = true;
              unsafeDiscardReferences.out = true;
            }
            ''
              mkdir -p "$out/${webRootDir}"
              cp ${wasmBundle}/${webRootDir}/* "$out/${webRootDir}/"
            '';
        webRoot = "${webBundle}/${webRootDir}";

        webPort = "8080"; # hosted-nodes spec §7.3: the provider edge proxies to internal_port 8080

        # The hosted-node launcher, mirroring bundleWithDaemon's --set-default discipline: every
        # value is a default an operator/provider env override still wins over (`''${VAR:-default}`),
        # and the daemon is exec'd so it is PID 1 and receives the runtime's stop signal directly
        # (SIGTERM and SIGINT both trip its graceful shutdown).
        hostedNodeLauncher = pkgs.writeShellApplication {
          name = "hosted-node";
          runtimeInputs = [ pkgs.coreutils ]; # mkdir -p in an otherwise-distroless container
          text = ''
            # Single-origin web front. TLS terminates at the provider edge; the public https
            # origin(s) must be added to DAEMON_API__WS_ALLOWED_ORIGINS by the provisioner (the
            # derived self-origin is http://<Host>).
            export DAEMON_WEB__ADDR="''${DAEMON_WEB__ADDR:-0.0.0.0:${webPort}}"
            export DAEMON_WEB__ROOT="''${DAEMON_WEB__ROOT:-${webRoot}}"

            # Durable state on the provider volume: sqlite store, auth db, blob CAS and workspaces
            # all root under DAEMON_DATA_DIR. The Unix socket lives under the data dir too - a
            # container image has no /tmp guarantee (the daemon's default) and the socket is
            # node-local.
            export DAEMON_DATA_DIR="''${DAEMON_DATA_DIR:-/data}"
            export DAEMON_STORE="''${DAEMON_STORE:-sqlite}"
            export DAEMON_SOCKET_PATH="''${DAEMON_SOCKET_PATH:-$DAEMON_DATA_DIR/daemon-api.sock}"

            # The daemon boots HOME-less since the hosted-boot hardening, but root HOME on the
            # volume anyway so anything home-derived (e.g. the hub-cache fallback) is durable.
            export HOME="''${HOME:-$DAEMON_DATA_DIR/home}"

            # Outbound TLS trust for the in-process genai client (Daemon Cloud attach / BYOK):
            # pin the store CA bundle unless the operator supplies one.
            export SSL_CERT_FILE="''${SSL_CERT_FILE:-${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt}"

            mkdir -p "$DAEMON_DATA_DIR" "$HOME"
            exec ${daemonBin}/bin/daemon "$@"
          '';
        };

        # The image root, also host-runnable (bin/hosted-node) and the microvm.nix seam. Unlike
        # bundleWithDaemon this deliberately EXCLUDES daemon-infer-llama: hosted plans forbid local
        # inference (it routes through Daemon Cloud attach or BYOK, both served by the in-process
        # genai client), and the llama-enabled worker would roughly double the image for a code
        # path disabled by config. Re-inclusion is one line: add daemonInferLlama to paths + a
        # DAEMON_INFER__WORKER_BIN default in the launcher.
        bundledWeb = pkgs.buildEnv {
          name = "daemon-web-bundled";
          paths = [
            hostedNodeLauncher
            daemonBin
            webBundle
          ];
        };

        # A layered image so the fat, slow-moving layers (glibc, the wasm bundle) are shared across
        # daemon-version pushes; the registry digest is the immutable ref the hosted-nodes control
        # plane pins. OCI tags forbid `+`, so the SemVer build-metadata separator becomes `_` in
        # the tag; the raw bundleVersion rides in the version label. No StopSignal override: the
        # runtime-default SIGTERM trips the daemon's graceful shutdown since the hosted-boot
        # hardening.
        hostedNodeOci = pkgs.dockerTools.buildLayeredImage {
          name = "daemon-hosted-node";
          tag = lib.replaceStrings [ "+" ] [ "_" ] bundleVersion;
          contents = [ bundledWeb ];
          # /data is the provider volume mountpoint; /tmp for anything std::env::temp_dir-shaped;
          # /opt/daemon/web is the spec's fixed bundle path, so a provisioner-injected
          # DAEMON_WEB__ROOT=/opt/daemon/web resolves to the same bundle the launcher defaults to
          # by store path.
          fakeRootCommands = ''
            mkdir -p ./data ./tmp ./opt/daemon
            chmod 1777 ./tmp
            ln -s ${webRoot} ./opt/daemon/web
          '';
          config = {
            Entrypoint = [ "/bin/hosted-node" ];
            ExposedPorts."${webPort}/tcp" = { };
            Volumes."/data" = { };
            Labels = {
              "org.opencontainers.image.version" = bundleVersion;
              "ai.daemon.role" = "hosted-node";
              "ai.daemon.web-port" = webPort;
            };
          };
        };

        # Where the canonical codegen script + the single authoritative CDDL live in daemon-node.
        codegenScript = ./daemon-node/crates/contracts/daemon-api/zcbor-codegen.sh;
        apiCddl = ./daemon-node/crates/contracts/daemon-api/daemon-api.cddl;
        # The checked-in copies daemon-app compiles (no Python/zcbor in the Qt build): the generated
        # codec, and the zcbor C runtime copied alongside it.
        vendoredCodec = ./daemon-app/src/core/daemon/codec/generated;
        vendoredRuntime = ./daemon-app/src/core/daemon/codec/vendor;

        codecFiles = [
          "daemon_api_client_decode.c"
          "daemon_api_client_decode.h"
          "daemon_api_client_encode.c"
          "daemon_api_client_encode.h"
          "daemon_api_client_types.h"
        ];
        # The zcbor runtime that `--copy-sources` emits; drift-checked too so a nixpkgs zcbor bump
        # can't desync the vendored runtime from the generated code.
        runtimeFiles = [
          "zcbor_common.c"
          "zcbor_common.h"
          "zcbor_decode.c"
          "zcbor_decode.h"
          "zcbor_encode.c"
          "zcbor_encode.h"
          "zcbor_print.c"
          "zcbor_print.h"
          "zcbor_tags.h"
        ];

        # Pure codegen: daemon-api contract (CDDL) + zcbor -> generated C/H AND the zcbor runtime
        # (--copy-sources), in the store. The single place codegen runs in CI; nothing here mutates
        # the working tree.
        daemon-zcbor-codec = pkgs.runCommand "daemon-zcbor-codec"
          {
            nativeBuildInputs = [ pkgs.python3Packages.zcbor pkgs.bash ];
          }
          ''
            mkdir -p "$out"
            bash ${codegenScript} ${apiCddl} "$out" --copy-sources
          '';
      in
      {
        packages = {
          inherit daemon-zcbor-codec;
          default = daemon-zcbor-codec;

          # Integration bundles: the GUI/TUI client with the daemon host binary co-packaged so
          # first-run "Local" works without a separately-installed daemon (CON-1b). Build with
          # `nix build '.?submodules=1#bundled-app'`, run with `nix run '.?submodules=1#bundled-app'`.
          bundled-app = bundledApp;
          bundled-tui = bundledTui;

          # The hosted-node deployment artifacts (CON-1b's web sibling; docs/hosted-node-image.md):
          # the daemon serving its own browser (WASM) GUI on one origin. `bundled-web` is the
          # host-runnable root; `hosted-node-oci` is the OCI image a hosting provider ingests
          # (docker-archive tarball; `podman load -i result-image`). Build with `just build-image`
          # or `nix build '.?submodules=1#hosted-node-oci'`. Linux-only in practice (the wasm
          # bundle needs the emscripten pin).
          bundled-web = bundledWeb;
          hosted-node-oci = hostedNodeOci;
        };

        checks = {
          # Fail if the vendored copy in daemon-app drifts from what the pinned daemon-node contract
          # generates. Pure: compares two store paths, never touches the working tree.
          codec-drift = pkgs.runCommand "codec-drift" { } ''
            gen=${daemon-zcbor-codec}
            fail=0
            check() {
              local src="$1" name="$2"; shift 2
              for f in "$@"; do
                if ! diff -u "$src/$f" "$gen/$f"; then
                  echo "DRIFT: daemon-app vendored $name/$f differs from generated" >&2
                  fail=1
                fi
              done
            }
            check ${vendoredCodec} generated ${pkgs.lib.concatStringsSep " " codecFiles}
            check ${vendoredRuntime} vendor ${pkgs.lib.concatStringsSep " " runtimeFiles}
            if [ "$fail" -ne 0 ]; then
              echo "vendored codec/runtime is stale vs the pinned daemon-node contract; run: nix run .#update-codec" >&2
              exit 1
            fi
            echo "vendored codec + runtime match the generated output"
            touch "$out"
          '';
        };

        apps = {
          # Run the co-packaged GUI/TUI client (daemon host binary discoverable via DAEMON_BIN), e.g.
          # `nix run '.?submodules=1#bundled-app'`.
          bundled-app = {
            type = "app";
            program = "${bundledApp}/bin/daemon-app";
            meta.description = "Run the daemon-app GUI bundled with the daemon host binary";
          };
          bundled-tui = {
            type = "app";
            program = "${bundledTui}/bin/daemon-tui";
            meta.description = "Run the daemon-tui client bundled with the daemon host binary";
          };

          # Host-local smoke run of the hosted-node launcher (the exact entrypoint the OCI image
          # boots), e.g.:
          #   DAEMON_WEB__ADDR=127.0.0.1:8080 DAEMON_DATA_DIR=/tmp/hosted-node \
          #     nix run '.?submodules=1#bundled-web'
          bundled-web = {
            type = "app";
            program = "${bundledWeb}/bin/hosted-node";
            meta.description = "Run the daemon serving its browser GUI on one origin (hosted-node launcher)";
          };

          # The one impure step: copy the pure codegen output into the working tree. Nix never mutates
          # the repo during a build, so updating checked-in files is an explicit `nix run`.
          update-codec = {
            type = "app";
            program =
              let
                script = pkgs.writeShellApplication {
                  name = "update-codec";
                  runtimeInputs = [ pkgs.coreutils ];
                  text = ''
                    gendest="daemon-app/src/core/daemon/codec/generated"
                    vendest="daemon-app/src/core/daemon/codec/vendor"
                    if [ ! -d "$gendest" ] || [ ! -d "$vendest" ]; then
                      echo "run from the superproject root (missing codec dirs)" >&2
                      exit 1
                    fi
                    for f in ${pkgs.lib.concatStringsSep " " codecFiles}; do
                      install -m644 "${daemon-zcbor-codec}/$f" "$gendest/$f"
                    done
                    for f in ${pkgs.lib.concatStringsSep " " runtimeFiles}; do
                      install -m644 "${daemon-zcbor-codec}/$f" "$vendest/$f"
                    done
                    echo "updated $gendest + $vendest from ${daemon-zcbor-codec}"
                  '';
                };
              in
              "${script}/bin/update-codec";
          };

          # Read-only default: a bare `nix run` never mutates the tree - it prints usage and reports
          # codec drift. Mutation requires `.#update-codec` explicitly.
          status = {
            type = "app";
            program =
              let
                script = pkgs.writeShellApplication {
                  name = "daemon-status";
                  runtimeInputs = [ pkgs.coreutils pkgs.diffutils ];
                  text = ''
                    echo "daemon superproject (read-only status)"
                    echo
                    echo "  nix run .#update-codec                                  regenerate vendored codec (mutates tree)"
                    echo "  nix build '.?submodules=1#checks.<system>.codec-drift'  gate: vendored vs generated"
                    echo "  just                                                    list build / codec / e2e tasks"
                    echo
                    gendest="daemon-app/src/core/daemon/codec/generated"
                    vendest="daemon-app/src/core/daemon/codec/vendor"
                    if [ ! -d "$gendest" ]; then
                      echo "codec: run from the superproject root to report drift"
                      exit 0
                    fi
                    drift=0
                    for f in ${pkgs.lib.concatStringsSep " " codecFiles}; do
                      if ! diff -q "${daemon-zcbor-codec}/$f" "$gendest/$f" >/dev/null 2>&1; then
                        drift=1
                      fi
                    done
                    for f in ${pkgs.lib.concatStringsSep " " runtimeFiles}; do
                      if ! diff -q "${daemon-zcbor-codec}/$f" "$vendest/$f" >/dev/null 2>&1; then
                        drift=1
                      fi
                    done
                    if [ "$drift" -eq 0 ]; then
                      echo "codec: in sync with the pinned daemon-node contract"
                    else
                      echo "codec: STALE - run: nix run .#update-codec"
                    fi
                  '';
                };
              in
              "${script}/bin/daemon-status";
          };

          default = self.apps.${system}.status;
        };

        # `just` is the entry point for every repo task (lint / deny / build-all / codec / e2e); the
        # recipes themselves re-enter the per-repo Nix devShells. Per AGENTS.md there are no host
        # tools, so the task runner must come from the flake too. Enter with `nix develop` (the
        # superproject build outputs still need `?submodules=1`, but this shell does not).
        devShells.default = pkgs.mkShell {
          # `just` runs every task; skopeo + jq are for the hosted-node image publish path
          # (`just push-image` / `verify-push`, docs/hosted-node-image.md §5) - pinned here so the
          # push pipeline uses the same versions everywhere rather than an ambient host skopeo.
          packages = [
            pkgs.just
            pkgs.skopeo
            pkgs.jq
          ];
        };

        # Opt-in code-review / tech-debt tooling. Entered explicitly (`nix develop .#review`, or via
        # the `just cursor` / MCP wrapper); never on the free default path. Sources `.env` at entry
        # so CS_ACCESS_TOKEN / GITHUB_TOKEN are available to cs / cs-mcp / mrva without baking any
        # secret into the store.
        devShells.review = pkgs.mkShell {
          packages = [
            pkgsUnfree.codeql
            mrva
            codescene-cli
            codescene-mcp
            pkgs.gh
            pkgs.jq
            pkgs.curl
            pkgs.unzip
          ];
          shellHook = ''
            set -a; [ -f "$PWD/.env" ] && . "$PWD/.env"; set +a
          '';
        };
      }
    );
}
