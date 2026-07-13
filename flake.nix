{
  description = "daemon superproject: cross-repo codec sync + end-to-end integration";

  # Pull built closures from the daemon-ai Cachix cache (public pull). CI feeds the cache
  # deterministically via cachix-action; humans/other machines opt in with --accept-flake-config
  # (or by being a trusted-user). Public pull key only — no secret lives here.
  # nix-community serves the `fenix` rust toolchain the children build with, so a superproject
  # build that has to realize the children from source substitutes the toolchain instead of
  # rederiving it (mirrors daemon-node's substituter set).
  nixConfig = {
    extra-substituters = [
      "https://daemon-ai.cachix.org"
      "https://nix-community.cachix.org"
      "https://cache.numtide.com"
    ];
    extra-trusted-public-keys = [
      "daemon-ai.cachix.org-1:jzeLmFDfgE5dzGT0RXF70IEU/tKsWdDV9LQ5zPGAnQs="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];
  };

  inputs = {
    # logos-co fork of nixos-unstable: carries the MinGW Qt cross fixes the children's Windows
    # outputs need. All three repos track the same fork so one nixpkgs eval backs the whole bundle.
    nixpkgs.url = "github:logos-co/nixpkgs/mingw-integration";
    flake-utils.url = "github:numtide/flake-utils";

    # The two children, consumed ONLY by the integration `bundled-*` outputs below (the daemon
    # binary shipped alongside the client so managed local-daemon spawn finds it - user story
    # CON-1b). These are path inputs into the submodules; evaluate with `?submodules=1` so their
    # working trees are populated. The codec outputs above do not use them, keeping codec-drift /
    # update-codec independent of the children's build closures.
    daemon-node.url = "path:./daemon-node";
    daemon-node.inputs.llm-agents.follows = "llm-agents";
    daemon-app.url = "path:./daemon-app";

    # Prebuilt coding-agent CLIs (claude-code, codex, gemini-cli, opencode, ...) for the `agents`
    # devShell below, mirroring daemon-node's `.#e2e` lane: they go on PATH so a node run from the
    # superproject (e.g. `nix run '.?submodules=1#bundled-app'`) can discover real foreign agents
    # (`daemon_acp::AcpDiscoverer`). Built + cache-populated against llm-agents' own pinned
    # nixpkgs and served from cache.numtide.com (added to nixConfig above), so this does not touch
    # our nixpkgs pin or require an allowUnfree flag on it.
    llm-agents.url = "github:numtide/llm-agents.nix";
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
    { self, nixpkgs, flake-utils, daemon-node, daemon-app, llm-agents }:
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

        # kwin-mcp (https://github.com/isac322/kwin-mcp): an MCP server that drives a
        # KWin/Wayland session over D-Bus + AT-SPI (window control, input injection,
        # screenshots, accessibility tree) — the GUI-automation companion to the
        # a11y-audit gate. Pure Python. Wired into Cursor via scripts/kwin-mcp +
        # .cursor/mcp.json, mirroring the cs-mcp precedent; NO host installs.
        #
        # Upstream builds with the `uv_build` backend, which the pinned nixpkgs does
        # not carry, so install the published pure-python wheel directly
        # (format = "wheel") rather than building from the sdist. GI-based: it
        # resolves the Atspi-2.0 + GLib typelibs through gobject-introspection at
        # import time, so wrap GI_TYPELIB_PATH onto the console scripts.
        kwin-mcp = pkgs.python3Packages.buildPythonApplication rec {
          pname = "kwin-mcp";
          version = "0.7.0";
          format = "wheel";
          src = pkgs.fetchurl {
            url = "https://files.pythonhosted.org/packages/d4/26/c57e82a8c17029b647ff2ba357e590c683e7f12db4aa631ba678ef5de6b1/kwin_mcp-${version}-py3-none-any.whl";
            hash = "sha256-9BdbNqKGmpxN+q15kskFqXsRvVpQeecT7iAyEidCRVk=";
          };
          # gobject-introspection provides the GI runtime; at-spi2-core + glib carry
          # the typelibs kwin_mcp.accessibility imports (Atspi-2.0, GLib/GObject/Gio).
          nativeBuildInputs = [ pkgs.gobject-introspection ];
          dependencies = with pkgs.python3Packages; [
            mcp
            pygobject3
            dbus-python
            pillow
          ];
          # No import check: kwin_mcp.accessibility calls gi.require_version("Atspi")
          # at module load, which needs the wrapped typelib path (set below), absent
          # from the bare build-check env.
          dontUsePythonImportsCheck = true;
          # NixOS reconciliation of the upstream wheel (it assumes an FHS distro):
          #  - session.py hardcodes /usr/lib/at-spi-bus-launcher (absent here);
          #    point it at the at-spi2-core store path.
          #  - it brings the private bus up with dbus-run-session, whose default
          #    session.conf has no <listen> on this host, so the bus never starts;
          #    the patch launches our own dbus-daemon with an explicit config.
          postInstall =
            let
              siteDir = "$out/${pkgs.python3Packages.python.sitePackages}/kwin_mcp";
            in
            ''
              patch -p1 -d ${siteDir} < ${./nix/kwin-mcp-nixos.patch}
              substituteInPlace ${siteDir}/session.py \
                --replace-fail '/usr/lib/at-spi-bus-launcher' \
                               '${pkgs.at-spi2-core}/libexec/at-spi-bus-launcher'
              cp ${./nix/kwin-mcp-atspi-input.py} ${siteDir}/atspi_input.py
              ${pkgs.python3}/bin/python3 ${./nix/kwin-mcp-core-fixups.py} ${siteDir}/core.py
            '';
          makeWrapperArgs = [
            "--prefix GI_TYPELIB_PATH : ${
              lib.makeSearchPath "lib/girepository-1.0" [
                pkgs.at-spi2-core
                pkgs.glib
                pkgs.gobject-introspection
              ]
            }"
            # kwin_mcp.input dlopens libei.so.1 (Wayland/libei input emulation) via
            # ctypes at import time; put it on the loader path.
            "--prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.libei ]}"
            # kwin_mcp shells out to these by bare name. Only the genuinely-missing
            # light tools are pinned here; kwin_wayland and spectacle come from the
            # host session on PATH (the plan's accepted host-KWin coupling), so this
            # --prefix augments rather than replaces the inherited PATH. Pulling the
            # whole pinned kdePackages.kwin would force a multi-hour KDE source build
            # for no benefit over the running host compositor.
            "--prefix PATH : ${
              lib.makeBinPath [
                pkgs.dbus # dbus-daemon + dbus-update-activation-environment
                pkgs.wl-clipboard # wl-copy/wl-paste (clipboard tools)
                pkgs.wtype # unicode typing
                pkgs.ydotool # input injection fallback (primary is libei/EIS)
                pkgs.bashInteractive
                pkgs.coreutils
              ]
            }"
          ];
          meta = {
            description = "MCP server for KWin/Wayland automation (window control, input, screenshots, AT-SPI)";
            homepage = "https://github.com/isac322/kwin-mcp";
            license = lib.licenses.mit;
            mainProgram = "kwin-mcp";
          };
        };

        # The built children for the integration bundles.
        daemonBin = daemon-node.packages.${system}.daemon;
        # The browser-enabled daemon (the `daemon` binary + the `browser` feature -> chromiumoxide
        # CDP). Shipped in the DOWNLOADABLE product bundles/installers below so the `browser` chat
        # tool is available out of the box. It embeds NO Chromium (its `chrome_path` stays unset),
        # so at runtime chromiumoxide auto-detects a Chromium already on the host's PATH (and the
        # tool stays off unless `[browser].enable` is set). The hosted-node OCI image keeps the lean,
        # browser-free `daemonBin` so the server image never carries the chromiumoxide bindings.
        daemonBrowserBin = daemon-node.packages.${system}.daemon-browser;
        # The local-inference worker, built WITH the llama engine (the daemon-node default build is
        # a stub worker with no engine at all — a bundle shipping that could download models but
        # never run one). The daemon spawns it per session for llama.cpp profiles.
        daemonInferLlama = daemon-node.packages.${system}.daemon-infer-llama;
        # Static-Qt desktop clients: fully self-contained (no dynamic Qt), the
        # terminal + OS keychain are compiled in. app-static emits both daemon-app
        # and daemon-tui; tui-static is a thin symlink view exposing just daemon-tui.
        guiApp = daemon-app.packages.${system}.app-static;
        tuiApp = daemon-app.packages.${system}.tui-static;

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
        # The product Sentry DSN (public ingest key — safe to embed; see docs/crash-reporting.md).
        # ONE value owned here at the bundle layer and threaded into both children: the app compiles
        # it in (-DDAEMON_APP_SENTRY_DSN, also the daemon-app child's own default) and reads it at
        # runtime as $DAEMON_APP_SENTRY_DSN; the node reads it at runtime as $DAEMON_SENTRY_DSN (it is
        # NOT compiled into the node), so the bundle wrapper must set it for the spawned daemon +
        # workers. An operator override of either env still wins (--set-default).
        sentryDsn = "https://500fed6a24304a5615c66ef479824fe6@o4511727459827712.ingest.de.sentry.io/4511727469199441";

        bundleWithDaemon =
          { app, name, mainProgram }:
          pkgs.symlinkJoin {
            inherit name;
            paths = [ app daemonBrowserBin daemonInferLlama ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              for client in daemon-app daemon-tui; do
                if [ -e "$out/bin/$client" ]; then
                  wrapProgram "$out/bin/$client" \
                    --set-default DAEMON_BIN "${daemonBrowserBin}/bin/daemon" \
                    --set-default DAEMON_INFER__WORKER_BIN "${daemonInferLlama}/bin/daemon-infer" \
                    --set-default DAEMON_APP_SERVICE_MODE "daemon" \
                    --set-default DAEMON_BUNDLE_VERSION "${bundleVersion}" \
                    --set-default DAEMON_APP_SENTRY_DSN "${sentryDsn}" \
                    --set-default DAEMON_SENTRY_DSN "${sentryDsn}"
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

        # --- packaged installers: embed the app+node bundle in every target that supports it -----
        # The child repo builds installer skeletons around the static-Qt app alone (its
        # DAEMON_APP_BUNDLED_* cache vars stay empty - a standalone daemon-app checkout has no node
        # binaries). This superproject is the layer that owns both children, so it injects the
        # prebuilt node binaries by appending those cache vars to the child's artifact derivations:
        #
        #   deb / rpm / AppImage / portable  bin/{daemon-app,daemon,daemon-infer,daemon-cli} (+
        #                                    lib/{libstdc++,libgomp} for the worker) - the packaging
        #                                    pre-build script patchelfs every staged ELF for the
        #                                    generic-distro floor
        #   NSIS (Windows)                   bin\{daemon-app.exe,daemon.exe,daemon-cli.exe,
        #                                    daemon-infer.exe} (+ the llama worker's ggml/llama/mtmd
        #                                    DLLs + MinGW runtime in bin\, beside the exe on the PE
        #                                    loader search path; vulkan-1.dll deliberately excluded -
        #                                    ggml-vulkan is a runtime-DL backend, CPU fallback else)
        #   DMG (macOS)                      same cache-var contract, filled on a mac host (needs
        #                                    aarch64-darwin node builds; packaging/macos/README.md)
        #   APK / WASM                       no embedding by design - thin remote clients; the wasm
        #                                    "bundle" is the inversion below (hosted-node-oci)
        #
        # Co-location is the whole discovery story: LocalDaemonLauncher probes bin/daemon next to
        # the app, the daemon's default worker_bin is a daemon-infer next to its own executable, and
        # the app's service-mode default is already Daemon - so the installed tree needs no wrapper
        # scripts and no environment.
        daemonCli = daemon-node.packages.${system}.daemon-cli;

        # The worker's engine runtime pair: daemon-infer-llama links libstdc++ + libgomp from the
        # nix gcc; target distros may ship older GLIBCXX, so the packages carry their own copies in
        # lib/ (the pre-build script rewrites bin rpaths to $ORIGIN/../lib).
        bundledRuntimeLibs = [
          "${pkgs.gcc.cc.lib}/lib/libstdc++.so.6"
          "${pkgs.gcc.cc.lib}/lib/libgomp.so.1"
        ];

        nodeBundleFlags = [
          "-DDAEMON_APP_BUNDLED_DAEMON=${daemonBrowserBin}/bin/daemon"
          "-DDAEMON_APP_BUNDLED_DAEMON_INFER=${daemonInferLlama}/bin/daemon-infer"
          "-DDAEMON_APP_BUNDLED_DAEMON_CLI=${daemonCli}/bin/daemon-cli"
          "-DDAEMON_APP_BUNDLED_LIBS=${lib.concatStringsSep ";" bundledRuntimeLibs}"
          # Compile the product DSN into the bundled app (the daemon-app child defaults it too; this
          # keeps the superproject the single owner of the value across every installer lane).
          "-DDAEMON_APP_SENTRY_DSN=${sentryDsn}"
        ];

        # Linux installers (deb / rpm / AppImage): the child's artifact build with the node
        # binaries appended. Later -D wins, so appending to cmakeFlags fills the empty cache vars.
        bundledLinuxArtifacts =
          (daemon-app.packages.${system}.artifacts.overrideAttrs (old: {
            pname = "daemon-bundled-linux-artifacts";
            cmakeFlags = old.cmakeFlags ++ nodeBundleFlags;
          }));

        selectBundledArtifact =
          name: glob:
          pkgs.runCommand "daemon-bundled-${name}" { } ''
            mkdir -p "$out"
            cp -v ${bundledLinuxArtifacts}/${glob} "$out"/
            cp -v ${bundledLinuxArtifacts}/${glob}.sha256 "$out"/ 2>/dev/null || true
          '';

        # Windows NSIS installer: daemon.exe + daemon-cli.exe + the llama-enabled daemon-infer.exe
        # engine worker, all cross-built by daemon-node's windows lane. The child's NSIS derivation
        # re-runs cmake with extra -D flags at the end of its configurePhase, so the injection
        # appends the same cache vars there.
        daemonWindows = daemon-node.packages.${system}.daemon-windows;
        daemonCliWindows = daemon-node.packages.${system}.daemon-cli-windows;
        # The Windows llama worker (x86_64-pc-windows-gnu, cargo features llama,mtmd), cross-built
        # FROM the current (Linux) system exactly like daemon-windows / daemon-cli-windows above.
        # Its bin/ carries daemon-infer.exe plus the ggml/llama/mtmd DLL closure + the MinGW runtime
        # AND a vulkan-1.dll (kept there for GPU-lane dev convenience) - which we deliberately do NOT
        # ship (see the DLL-collection guard below).
        daemonInferLlamaWindows = daemon-node.packages.${system}.daemon-infer-llama-windows;
        bundledNsis = daemon-app.packages.${system}.nsis.overrideAttrs (old: {
          pname = "daemon-bundled-windows-nsis";
          configurePhase = old.configurePhase + ''
            # Collect the worker's runtime DLLs by glob from its bin/, EXCLUDING vulkan-1.dll.
            # ggml-vulkan.dll is a GGML_BACKEND_DL backend dlopen()ed at startup; on a machine with a
            # GPU driver the system provides the vulkan-1 loader, and on a driverless machine the
            # backend simply fails to load and ggml falls back to ggml-cpu.dll. Shipping our own
            # vulkan-1.dll would mask that fallback, so it is dropped from the installed tree.
            # Globbing (rather than hardcoding names) tolerates upstream ggml DLL renames; a minimum
            # core set is asserted below.
            infer_bin='${daemonInferLlamaWindows}/bin'
            win_libs=""
            for dll in "$infer_bin"/*.dll; do
              bn="$(basename "$dll")"
              [ "$bn" = "vulkan-1.dll" ] && continue
              win_libs="''${win_libs:+$win_libs;}$dll"
            done
            # Assert the core engine DLLs are present (fail loud if the worker output changed shape).
            # ggml DLLs are unprefixed, llama/mtmd are lib-prefixed - accept either spelling.
            for core in ggml ggml-base ggml-cpu ggml-vulkan llama mtmd; do
              if [ ! -e "$infer_bin/$core.dll" ] && [ ! -e "$infer_bin/lib$core.dll" ]; then
                echo "FATAL: bundled windows worker missing core DLL '$core' in $infer_bin" >&2
                ls -la "$infer_bin" >&2
                exit 1
              fi
            done
            # Regression guard: vulkan-1.dll must never reach the bundled set.
            case ";$win_libs;" in
              *"/vulkan-1.dll;"*)
                echo "FATAL: vulkan-1.dll leaked into DAEMON_APP_BUNDLED_LIBS" >&2
                exit 1
                ;;
            esac

            cmake \
              -DDAEMON_APP_BUNDLED_DAEMON=${daemonWindows}/bin/daemon.exe \
              -DDAEMON_APP_BUNDLED_DAEMON_CLI=${daemonCliWindows}/bin/daemon-cli.exe \
              -DDAEMON_APP_BUNDLED_DAEMON_INFER=${daemonInferLlamaWindows}/bin/daemon-infer.exe \
              -DDAEMON_APP_BUNDLED_LIBS="$win_libs" \
              .
          '';
        });

        # --- apps.smoke-windows (composed E2E under wine) ------------------------------
        # Best-effort wine E2E of the COMPOSED installer (NOT a flake check; wine is emulation, not
        # Windows, and needs wineserver/network features the nix build sandbox forbids - same split
        # as daemon-app's apps.windows-smoke / apps.portable-smoke). Reuses the exact nix-provided
        # (WoW64) wine from daemon-app's windows stack + the same hardened, hermetic prelude
        # (throwaway prefix, gecko/mono + their fetches disabled, offscreen QPA, kill-then-wait
        # wineserver teardown), and drives the full co-located flow: silent PER-USER install of
        # package-nsis (no /D - the compiled-in $LOCALAPPDATA\Programs\Daemon default the
        # SelfApply updater relies on), assert the installed tree ships all three exes +
        # daemon-updater.exe, `--version` daemon + daemon-cli, boot the installed daemon-app.exe
        # in daemon mode (offscreen, WAIT_READY + WAIT_CONNECTED) so it spawns the co-located
        # daemon.exe and connects over the named pipe (the pipe-name contract), then a daemon-cli
        # `status` call over that same pipe, and finally the uninstaller presence.
        smokeWindows = pkgs.writeShellApplication {
          name = "smoke-windows";
          runtimeInputs = [ daemon-app.packages.${system}.windows-smoke-wine ];
          text = ''
            tmp=$(mktemp -d)
            export HOME="$tmp/home" && mkdir -p "$HOME"
            export WINEPREFIX="$tmp/prefix"
            export WINEDEBUG=-all
            # Kill the gecko/mono install prompts AND their network fetches - hermetic + offline.
            export WINEDLLOVERRIDES="mscoree,mshtml="
            # Headless boot: the offscreen QPA plugin is compiled into daemon-app.exe.
            export QT_QPA_PLATFORM=offscreen
            export QT_QUICK_BACKEND=software
            # Teardown: the app-spawned daemon.exe is deliberately left serving its pipe (the
            # cli-status step talks to it), so a bare `wineserver -w` would wait forever. Kill
            # everything in the prefix (-k) first, then wait (-w) so nothing races the rm.
            trap 'wineserver -k 2>/dev/null || true; wineserver -w 2>/dev/null || true; rm -rf "$tmp"' EXIT

            installerExe=$(find ${bundledNsis} -maxdepth 1 -name 'daemon-*-win64.exe' -print -quit)
            status=0

            # Deterministic connection target: the daemon (DAEMON_SOCKET_PATH), the app
            # (DAEMON_APP_SOCKET -> QLocalSocket) and the CLI all derive the SAME named pipe from
            # this exact string via the pipe-name contract. A plain Windows path; the launcher
            # creates its parent dir before spawning the daemon.
            sock='C:\daemon-e2e\daemon.sock'
            export DAEMON_SOCKET_PATH="$sock"
            export DAEMON_APP_SOCKET="$sock"
            export DAEMON_APP_SERVICE_MODE=daemon
            export DAEMON_APP_WAIT_READY=60000
            export DAEMON_APP_WAIT_CONNECTED=1

            echo "== smoke-windows: wineboot (fresh prefix) =="
            wineboot --init >/dev/null 2>&1 || true

            echo "== smoke-windows: NSIS silent PER-USER install (/S, no /D) =="
            # No /D override: exercise the compiled-in per-user default root
            # ($LOCALAPPDATA\Programs\Daemon) - the promptless tree SelfApply swaps in place.
            if wine "$installerExe" /S > "$tmp/install.log" 2>&1; then
              inst_rc=0
            else
              inst_rc=$?
            fi
            # Resolve the per-user install dir by glob (the wine username varies).
            bindir=""
            for f in "$WINEPREFIX"/drive_c/users/*/AppData/Local/Programs/Daemon/bin/daemon-app.exe; do
              if [ -f "$f" ]; then bindir=$(dirname "$f"); break; fi
            done
            if [ "$inst_rc" != 0 ] || [ -z "$bindir" ]; then
              echo "smoke-windows: silent per-user install FAILED under wine (exit $inst_rc)"
              echo "  (expected tree under drive_c/users/*/AppData/Local/Programs/Daemon/bin)"
              tail -n 20 "$tmp/install.log" || true
              exit 1
            fi
            echo "smoke-windows: silent per-user install OK ($bindir)"
            # Regression guard: a per-machine install would land here instead.
            if [ -e "$WINEPREFIX/drive_c/Program Files/Daemon" ]; then
              echo "smoke-windows: FAIL install landed in Program Files (per-user switch regressed)"
              status=1
            fi

            echo "== smoke-windows: installed tree carries the bundle exes =="
            for exe in daemon-app.exe daemon.exe daemon-cli.exe daemon-updater.exe daemon-infer.exe; do
              if [ -f "$bindir/$exe" ]; then
                echo "  present: $exe"
              else
                echo "  MISSING: $exe"
                status=1
              fi
            done

            echo "== smoke-windows: llama worker engine DLLs ship beside the exe in bin/ =="
            # ggml DLLs are unprefixed, llama/mtmd carry the MinGW lib prefix - accept either.
            have_dll() { [ -f "$bindir/$1.dll" ] || [ -f "$bindir/lib$1.dll" ]; }
            for core in ggml ggml-base ggml-cpu ggml-vulkan llama mtmd; do
              if have_dll "$core"; then
                echo "  present: $core (.dll or lib$core.dll)"
              else
                echo "  MISSING engine DLL: $core"
                status=1
              fi
            done
            # MinGW runtime the worker links (mcfgthread, NOT winpthread).
            for rt in libstdc++-6.dll libgcc_s_seh-1.dll libmcfgthread-2.dll; do
              if [ -f "$bindir/$rt" ]; then
                echo "  present: $rt"
              else
                echo "  MISSING mingw runtime: $rt"
                status=1
              fi
            done

            echo "== smoke-windows: vulkan-1.dll must NOT ship anywhere in the installed tree =="
            # The daemon dir (bin + any sibling) is the whole per-user install; scan it all.
            installroot="$(dirname "$bindir")"
            vk_hits=$(find "$installroot" -iname 'vulkan-1.dll' 2>/dev/null || true)
            if [ -n "$vk_hits" ]; then
              echo "  FAIL: vulkan-1.dll present in the installed tree:"
              echo "$vk_hits"
              status=1
            else
              echo "  ok: no vulkan-1.dll anywhere (this run is the CPU-fallback proof)"
            fi

            echo "== smoke-windows: daemon-infer.exe --version (CPU fallback; no vulkan loader) =="
            # With no vulkan-1.dll present, ggml_backend_load_all() cannot load ggml-vulkan.dll and
            # silently falls back to ggml-cpu.dll; a clean --version exit proves that fallback path.
            if wine "$bindir/daemon-infer.exe" --version > "$tmp/infer-version.log" 2>&1; then
              infer_line="$(tr -d '\r' < "$tmp/infer-version.log" | tail -n1)"
              echo "  daemon-infer.exe --version: $infer_line"
              if printf '%s' "$infer_line" | grep -q 'daemon-infer'; then
                echo "  ok: version output contains 'daemon-infer'"
              else
                echo "  FAIL: version output missing 'daemon-infer'"
                status=1
              fi
            else
              echo "  daemon-infer.exe --version FAILED"
              tail -n 5 "$tmp/infer-version.log" || true
              status=1
            fi

            echo "== smoke-windows: daemon.exe / daemon-cli.exe --version =="
            if wine "$bindir/daemon.exe" --version > "$tmp/daemon-version.log" 2>&1; then
              echo "  daemon.exe --version: $(tr -d '\r' < "$tmp/daemon-version.log" | tail -n1)"
            else
              echo "  daemon.exe --version FAILED"
              tail -n 5 "$tmp/daemon-version.log" || true
              status=1
            fi
            if wine "$bindir/daemon-cli.exe" --version > "$tmp/cli-version.log" 2>&1; then
              echo "  daemon-cli.exe --version: $(tr -d '\r' < "$tmp/cli-version.log" | tail -n1)"
            else
              echo "  daemon-cli.exe --version FAILED"
              tail -n 5 "$tmp/cli-version.log" || true
              status=1
            fi

            echo "== smoke-windows: app spawns co-located daemon.exe + connects over the pipe =="
            if wine "$bindir/daemon-app.exe" > "$tmp/app.log" 2>&1; then
              app_rc=0
            else
              app_rc=$?
            fi
            tail -n 25 "$tmp/app.log" || true
            if grep -q "DAEMON_APP_READY ok" "$tmp/app.log"; then
              echo "smoke-windows: app<->daemon connected (DAEMON_APP_READY ok)"
            else
              echo "smoke-windows: app<->daemon connect FAILED under wine (exit $app_rc)"
              status=1
            fi

            echo "== smoke-windows: daemon-cli.exe status over the named pipe =="
            cli_ok=0
            for _ in 1 2 3 4 5; do
              if wine "$bindir/daemon-cli.exe" status > "$tmp/cli-status.log" 2>&1; then
                cli_ok=1
                break
              fi
              sleep 1
            done
            tail -n 20 "$tmp/cli-status.log" || true
            if [ "$cli_ok" = 1 ]; then
              echo "smoke-windows: daemon-cli status OK over the pipe"
            else
              echo "smoke-windows: daemon-cli status FAILED over the pipe"
              status=1
            fi

            echo "== smoke-windows: uninstaller present =="
            uninst=$(find "$(dirname "$bindir")" -maxdepth 1 -name 'Uninstall*.exe' -print -quit 2>/dev/null || true)
            if [ -n "$uninst" ]; then
              echo "smoke-windows: uninstaller present ($(basename "$uninst"))"
            else
              echo "smoke-windows: uninstaller MISSING"
              status=1
            fi

            exit "$status"
          '';
        };

        # macOS DMG (aarch64-darwin): the darwin twin of bundledLinuxArtifacts /
        # bundledNsis. daemon-app's DragNDrop artifact with the node binaries
        # appended to its cmakeFlags, so the DAEMON_APP_BUNDLED_* cache vars land
        # daemon / daemon-cli / daemon-infer into Contents/MacOS next to the app
        # executable - LocalDaemonLauncher discovers them there, no wrapper. Later
        # -D wins, so appending fills the child's empty cache vars. The child's
        # macos-dmg output is itself darwin-only (dynamic null attr name), so this
        # is referenced only from the aarch64-darwin packages branch below; keeping
        # it a lazy let binding means the Linux package set never forces it.
        #
        # The Apple worker is daemon-infer-metal (llama,mtmd,metal): its Mach-O links
        # only /System/Library frameworks, so it needs NO sidecar dylibs and NO
        # .metallib (the Metal shaders are embedded and JIT-compiled at runtime) -
        # hence no DAEMON_APP_BUNDLED_LIBS on darwin. daemon-infer-metal lives in
        # daemon-node's aarch64-darwin package set; this binding (like bundledDmg) is
        # forced only on that system, so the Linux eval never touches it.
        daemonInferMetal = daemon-node.packages.${system}.daemon-infer-metal;
        # macos-dmg is the static-Qt macOS build (daemon-app/nix/macos.nix): a
        # self-contained .app (Qt compiled in, no macdeployqt) packaged as a
        # drag-and-drop .dmg, with sentry-native + the co-located crashpad_handler
        # wired into the bundle. This .overrideAttrs only injects the sibling node
        # binaries + the product DSN; it consumes macos-dmg unchanged. Built + crash
        # smoke-verified on the aarch64-darwin M1 mini via the release.yml macos lane.
        bundledDmg = daemon-app.packages.${system}.macos-dmg.overrideAttrs (old: {
          pname = "daemon-bundled-macos-dmg";
          cmakeFlags = old.cmakeFlags ++ [
            "-DDAEMON_APP_BUNDLED_DAEMON=${daemonBrowserBin}/bin/daemon"
            "-DDAEMON_APP_BUNDLED_DAEMON_INFER=${daemonInferMetal}/bin/daemon-infer"
            "-DDAEMON_APP_BUNDLED_DAEMON_CLI=${daemonCli}/bin/daemon-cli"
            # Superproject-owned product DSN (also the daemon-app child default; explicit here so the
            # DMG lane's compiled-in value is unambiguous). macOS crashpad is the default backend.
            "-DDAEMON_APP_SENTRY_DSN=${sentryDsn}"
          ];
        });

        # Portable bundle: the child's portable static-Qt layout plus the node binaries, rewired
        # exactly like the installer payloads (generic loader, $ORIGIN rpaths, runtime libs in
        # lib/), and its one-file tarball. This is the "unpack anywhere on x86_64 Linux" artifact;
        # glibc floor = max(app 2.38, daemon 2.39) - printed by the child's boot smoke and the
        # release manifest.
        appPortable = daemon-app.packages.${system}.portable;
        bundledPortable = pkgs.runCommand "daemon-bundle-portable-${bundleVersion}" {
          nativeBuildInputs = [ pkgs.patchelf ];
        } ''
          mkdir -p "$out/bin" "$out/lib"
          cp -r ${appPortable}/share "$out/share"
          cp ${appPortable}/bin/daemon-app "$out/bin/daemon-app"

          install -m755 ${daemonBrowserBin}/bin/daemon "$out/bin/daemon"
          install -m755 ${daemonInferLlama}/bin/daemon-infer "$out/bin/daemon-infer"
          install -m755 ${daemonCli}/bin/daemon-cli "$out/bin/daemon-cli"
          for so in ${lib.concatStringsSep " " bundledRuntimeLibs}; do
            install -m755 "$so" "$out/lib/$(basename "$so")"
          done

          chmod -R u+w "$out/bin" "$out/lib"
          for bin in "$out"/bin/*; do
            patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 \
                     --set-rpath '$ORIGIN:$ORIGIN/../lib' "$bin"
          done
          for so in "$out"/lib/*.so*; do
            patchelf --set-rpath '$ORIGIN' "$so"
          done
        '';
        bundledPortableTarball = pkgs.runCommand "daemon-bundle-portable-tarball-${baseVersion}" {
          nativeBuildInputs = [ pkgs.zstd ];
        } ''
          mkdir -p "$out" staging/daemon-portable-x86_64
          cp -r ${bundledPortable}/. staging/daemon-portable-x86_64/
          tar -C staging \
            --sort=name --owner=0 --group=0 --numeric-owner --mtime='@1' \
            -cf - daemon-portable-x86_64 \
            | zstd -19 -T0 -o "$out/daemon-portable-x86_64.tar.zst"
        '';

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

        # The SECOND emitter on this pipeline (spec 09 §3.6 / ADR-004): CDDL + the human-owned
        # entity map -> vendored Q_GADGET entity artifacts, drift-gated exactly like the zcbor codec.
        # The generator lives beside zcbor-codegen.sh in daemon-node (contract-owning repo); the map
        # and the generated artifacts live in daemon-app.
        mirrorCodegenDir = ./daemon-node/crates/contracts/daemon-api/mirror-codegen;
        entityMap = ./daemon-app/src/core/mirror/entity-map.toml;
        vendoredMirror = ./daemon-app/src/core/mirror/generated;
        mirrorMapCpp = ./daemon-app/src/core/mirror/entities_map.cpp;
        # The four byte-identical (drift-checked) mirror artifacts; entities_map.cpp is human-owned
        # (signature-checked only, never byte-compared) and so is NOT in this list.
        mirrorFiles = [
          "entities_gen.h"
          "entities_provenance_gen.h"
          "entities_map_gen.h"
          "mirror_schema_gen.sql"
        ];

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

        # Pure mirror-entity codegen: the pinned CDDL + entity map -> the four vendored artifacts,
        # in the store. Pure Python stdlib (tomllib + a small CDDL member index); no third-party
        # deps, so the drift gate is deterministic. Nothing here mutates the working tree.
        daemon-mirror-entities = pkgs.runCommand "daemon-mirror-entities"
          {
            nativeBuildInputs = [ pkgs.python3 ];
          }
          ''
            mkdir -p "$out"
            python3 ${mirrorCodegenDir}/entity_codegen.py \
              --cddl ${apiCddl} --map ${entityMap} --out "$out"
          '';
      in
      {
        packages = {
          inherit daemon-zcbor-codec;
          inherit daemon-mirror-entities;
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

          # Shippable installers with the app+node bundle embedded (see the bundle-matrix comment
          # above; `just package-linux` / `package-windows` / `package-portable`). `package-*` =
          # what a user downloads; the plain `bundled-*` outputs above stay the nix-native
          # run-from-store form of the same product.
          package-linux = bundledLinuxArtifacts;
          package-appimage = selectBundledArtifact "appimage" "*.AppImage";
          package-deb = selectBundledArtifact "deb" "*.deb";
          package-rpm = selectBundledArtifact "rpm" "*.rpm";
          package-nsis = bundledNsis;
          package-portable = bundledPortable;
          package-portable-tarball = bundledPortableTarball;

          # kwin-mcp: the KWin/Wayland GUI-automation MCP server (see the derivation
          # above). Launched by scripts/kwin-mcp and referenced from .cursor/mcp.json.
          inherit kwin-mcp;
        }
        # macOS DMG with the node bundle embedded, built on a mac host only
        # (aarch64-darwin). `just package-dmg` / `nix build '.?submodules=1#package-dmg'`.
        // lib.optionalAttrs (system == "aarch64-darwin") {
          package-dmg = bundledDmg;
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
            # Mirror entity artifacts (spec §3.6): byte-identical regeneration of the four artifacts,
            # provenance completeness + CDDL grounding (re-run inside the generator), the
            # no-client_local-in-a-mirror-table rule, and mapper signature match vs the vendored
            # codec types. entity_drift.py imports entity_codegen.py from the same store dir.
            if ! ${pkgs.python3}/bin/python3 ${mirrorCodegenDir}/entity_drift.py \
                 --cddl ${apiCddl} --map ${entityMap} \
                 --generated-dir ${vendoredMirror} --map-cpp ${mirrorMapCpp} \
                 --types-header ${vendoredCodec}/daemon_api_client_types.h; then
              echo "DRIFT: vendored mirror entity artifacts differ from generated" >&2
              fail=1
            fi
            if [ "$fail" -ne 0 ]; then
              echo "vendored codec/runtime/mirror is stale vs the pinned daemon-node contract; run: nix run .#update-codec" >&2
              exit 1
            fi
            echo "vendored codec + runtime + mirror entities match the generated output"
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

          # Composed Windows E2E under wine: silent-install the bundled NSIS installer and validate
          # the full co-located app<->daemon(named pipe)<-cli flow. Best-effort (wine is emulation),
          # non-gating; run with `just smoke-windows` or
          # `nix run '.?submodules=1#smoke-windows'`.
          smoke-windows = {
            type = "app";
            program = "${smokeWindows}/bin/smoke-windows";
            meta.description = "Silent-install the composed NSIS installer under wine and validate the app+daemon+cli named-pipe flow";
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

                    # Mirror entity artifacts (spec §3.6, the second emitter).
                    mirdest="daemon-app/src/core/mirror/generated"
                    if [ ! -d "$mirdest" ]; then
                      echo "run from the superproject root (missing mirror dir)" >&2
                      exit 1
                    fi
                    for f in ${pkgs.lib.concatStringsSep " " mirrorFiles}; do
                      install -m644 "${daemon-mirror-entities}/$f" "$mirdest/$f"
                    done
                    # The one-time mapper skeleton is human-owned: bootstrap it only when absent;
                    # regeneration NEVER overwrites it (the drift gate checks signatures, not bodies).
                    if [ ! -f "daemon-app/src/core/mirror/entities_map.cpp" ]; then
                      ${pkgs.python3}/bin/python3 ${mirrorCodegenDir}/entity_codegen.py \
                        --cddl ${apiCddl} --map ${entityMap} \
                        --emit-skeleton "daemon-app/src/core/mirror/entities_map.cpp"
                    fi
                    echo "updated $mirdest from ${daemon-mirror-entities}"
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

        # Foreign-agent CLIs on PATH for whole-product e2e: run a bundled node from the superproject
        # (`nix run '.?submodules=1#bundled-app'`) inside this shell so its ACP discovery
        # (`daemon_acp::AcpDiscoverer`) probes real coding-agent binaries. Mirrors daemon-node's
        # `.#e2e` curated set, but as a superproject-native shell it needs no `?submodules=1` (the
        # agents come straight from the `llm-agents` input + cache.numtide.com, not the children).
        # The `want` set is filtered against what `llm-agents` exposes for this system, so an absent
        # attr (or unsupported platform) is skipped rather than breaking eval. Unfree agents are
        # instantiated by llm-agents' own unfree-permitting nixpkgs, so this needs no allowUnfree on
        # our pin.
        devShells.agents =
          let
            a = llm-agents.packages.${system} or { };
            want = [
              "gemini-cli"
              "qwen-code"
              "goose-cli"
              "opencode"
              "codex"
              "cursor-agent"
              "copilot-cli"
              "droid"
              "iflow-cli"
              "qoder-cli"
              "kilocode-cli"
              "mistral-vibe"
              "junie"
              "eca"
              "claude-code"
              "amp"
            ];
            agents = map (n: a.${n}) (builtins.filter (n: a ? ${n}) want);
          in
          pkgs.mkShell {
            packages = [
              pkgs.just
              pkgs.jq
            ] ++ agents;
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
