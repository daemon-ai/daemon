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

# Build everything the E2E suite needs.
build-all: build-node build-app build-tui

# --- codec contract -------------------------------------------------------

# Prove the generated C codec round-trips real ciborium fixtures (daemon-node).
verify-codec:
    cd daemon-node && nix build ".#checks.{{system}}.verify-codec" -L

# Fail if daemon-app's vendored codec drifts from the daemon-node contract.
codec-drift:
    nix build ".?submodules=1#checks.{{system}}.codec-drift" -L

# Regenerate the vendored codec into the working tree from the contract.
update-codec:
    nix run ".?submodules=1#update-codec"

# --- end-to-end -----------------------------------------------------------

# Run the cross-repo E2E suite against freshly built binaries.
e2e: build-node
    #!/usr/bin/env bash
    set -euo pipefail
    nix build ./daemon-app#default --out-link result-app
    nix build ./daemon-app#tui --out-link result-tui
    export DAEMON_BIN="$PWD/daemon-node/target/debug/daemon"
    export DAEMON_CLI_BIN="$PWD/daemon-node/target/debug/daemon-cli"
    export CLIENT_GUI_BIN="$PWD/result-app/bin/daemon-app"
    export CLIENT_TUI_BIN="$PWD/result-tui/bin/daemon-tui"
    cd system-tests && nix develop ../daemon-node --command cargo test -- --test-threads=1

# Run only the protocol-trace scenarios (daemon + CLI; no client binaries needed).
e2e-protocol: build-node
    #!/usr/bin/env bash
    set -euo pipefail
    export DAEMON_BIN="$PWD/daemon-node/target/debug/daemon"
    export DAEMON_CLI_BIN="$PWD/daemon-node/target/debug/daemon-cli"
    cd system-tests && nix develop ../daemon-node --command cargo test --test protocol_trace -- --test-threads=1
