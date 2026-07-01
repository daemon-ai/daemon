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

# Build the client bundles that co-package the daemon host binary (so first-run "Local" can spawn a
# local daemon without a separate install - user story CON-1b). Submodule-aware, like the codec.
bundle:
    nix build ".?submodules=1#bundled-app" --out-link result-bundled-app
    nix build ".?submodules=1#bundled-tui" --out-link result-bundled-tui

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
