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

# Regenerate the vendored codec, then build everything (the "clean automatic" path).
sync: update-codec build-all

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

# --- lint / format gates --------------------------------------------------
# Tools come from the per-repo Nix devShells (`nix develop`), so these run the same
# pinned versions everywhere. `lint` is the umbrella gate; the sub-recipes run a single
# language. The Rust gate uses default features to mirror the workspace CI gate (the engine
# lanes - llama/mistralrs/hyperon - are deliberately separate outputs that need native libs).

# Run every fast static gate (Rust + C++/QML + secrets + spelling).
lint: lint-rust lint-cpp secrets spell

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
