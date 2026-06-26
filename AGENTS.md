# AGENTS.md — daemon superproject

Nix-managed monorepo. Two independent submodules: `daemon-node` (Rust backend) and
`daemon-app` (Qt 6 QML + TUI client). All tooling lives in Nix devShells — there are NO host
tools. Run everything via `just` (which wraps `nix develop`) or `nix develop --command ...`.

## Before you call any change "done"

- `just lint`   # rustfmt + clippy (-D warnings) + clang-tidy + clang-format + qmllint + secrets + spell
- `just deny`   # dependency advisories / licenses / bans / sources
- Build + test what you touched: `just build-all`, and the relevant `just e2e` / per-repo tests.

Install the pre-commit hook once per clone: `just install-hooks`. Never bypass it
(`git commit --no-verify` is forbidden).

## Codec contract (do not edit generated code by hand)

The vendored C codec under `daemon-app/src/core/daemon/codec/{generated,vendor}` is generated
from the `daemon-node` CDDL contract.

- `just codec-drift`  # gate: vendored copy vs the pinned contract
- `just update-codec` # regenerate into the working tree after a contract change

## Occasional cleanup (advisory — never blind-delete)

`just audit-cleanup` (unused deps, unused functions, duplication, unused includes), plus
`just hack`, `just sanitize`, `just miri`, `just fuzz`, `just mutants`, `just coverage`.

Results are CANDIDATES, not instructions: Qt signals/slots, QML-invoked methods,
`#[no_mangle]`/FFI exports, and feature-gated code routinely show up as false positives.
Delete in small, verified batches.

## Language specifics

See `daemon-node/AGENTS.md` (Rust) and `daemon-app/AGENTS.md` (C++/QML). Each submodule is its
own git repo and its AGENTS.md is self-contained for standalone checkouts.
