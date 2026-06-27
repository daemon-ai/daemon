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

        # The built children for the integration bundles.
        daemonBin = daemon-node.packages.${system}.daemon;
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
        bundleWithDaemon =
          { app, name, mainProgram }:
          pkgs.symlinkJoin {
            inherit name;
            paths = [ app daemonBin ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              for client in daemon-app daemon-tui; do
                if [ -e "$out/bin/$client" ]; then
                  wrapProgram "$out/bin/$client" \
                    --set-default DAEMON_BIN "${daemonBin}/bin/daemon" \
                    --set-default DAEMON_APP_SERVICE_MODE "daemon"
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
      }
    );
}
