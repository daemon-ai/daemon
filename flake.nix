{
  description = "daemon superproject: cross-repo codec sync + end-to-end integration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  # NOTE: the daemon-node / daemon-app submodule contents are gitlinks, so this flake must be
  # evaluated with submodule visibility, e.g. `nix build '.?submodules=1#daemon-zcbor-codec'`.
  # The justfile wraps the common commands so callers don't have to remember the flag.
  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Where the authoritative contract + canonical codegen script live in the daemon-node submodule.
        codegenScript = ./daemon-node/crates/contracts/daemon-api/zcbor-codegen.sh;
        smokeCddl = ./daemon-node/crates/contracts/daemon-api/zcbor-smoke.cddl;
        # The checked-in copy daemon-app compiles (no Python/zcbor in the Qt build).
        vendoredCodec = ./daemon-app/src/core/daemon/codec/generated;

        codecFiles = [
          "daemon_api_smoke_decode.c"
          "daemon_api_smoke_decode.h"
          "daemon_api_smoke_encode.c"
          "daemon_api_smoke_encode.h"
          "daemon_api_smoke_types.h"
        ];

        # Pure codegen: daemon-api contract (CDDL) + zcbor -> generated C/H, in the store. This is the
        # single place codegen runs in CI; nothing here mutates the working tree.
        daemon-zcbor-codec = pkgs.runCommand "daemon-zcbor-codec"
          {
            nativeBuildInputs = [ pkgs.python3Packages.zcbor pkgs.bash ];
          }
          ''
            mkdir -p "$out"
            bash ${codegenScript} ${smokeCddl} "$out"
          '';
      in
      {
        packages = {
          inherit daemon-zcbor-codec;
          default = daemon-zcbor-codec;
        };

        checks = {
          # Fail if the vendored copy in daemon-app drifts from what the pinned daemon-node contract
          # generates. Pure: compares two store paths, never touches the working tree.
          codec-drift = pkgs.runCommand "codec-drift" { } ''
            gen=${daemon-zcbor-codec}
            vend=${vendoredCodec}
            fail=0
            for f in ${pkgs.lib.concatStringsSep " " codecFiles}; do
              if ! diff -u "$vend/$f" "$gen/$f"; then
                echo "DRIFT: daemon-app vendored $f differs from generated" >&2
                fail=1
              fi
            done
            if [ "$fail" -ne 0 ]; then
              echo "vendored codec is stale vs the pinned daemon-node contract; run: nix run .#update-codec" >&2
              exit 1
            fi
            echo "vendored codec matches the generated codec"
            touch "$out"
          '';
        };

        apps = {
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
                    dest="daemon-app/src/core/daemon/codec/generated"
                    if [ ! -d "$dest" ]; then
                      echo "run from the superproject root (missing $dest)" >&2
                      exit 1
                    fi
                    for f in ${pkgs.lib.concatStringsSep " " codecFiles}; do
                      install -m644 "${daemon-zcbor-codec}/$f" "$dest/$f"
                    done
                    echo "updated $dest from ${daemon-zcbor-codec}"
                  '';
                };
              in
              "${script}/bin/update-codec";
          };
          default = self.apps.${system}.update-codec;
        };
      }
    );
}
