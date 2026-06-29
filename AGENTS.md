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

## Code review / tech-debt tooling (opt-in `review` shell)

CodeScene + mrva live in a dedicated, unfree-gated `nix develop .#review` shell (codeql + mrva +
the CodeScene `cs` CLI + the `cs-mcp` MCP server). The free `default` shell never references them,
so a free-only checkout is unaffected. The shell sources the gitignored `.env`
(`CS_ACCESS_TOKEN`, `GITHUB_TOKEN`) at entry; secrets never land in tracked files.

- `just cursor`              # launch Cursor inside `.#review` (cs / cs-mcp / mrva / codeql on PATH)
- `just code-health <file>`  # CodeScene Code Health of a file (lint-style)
- `just cs-projects`         # list CodeScene Cloud projects (find a project id)
- `just hotspots <id>`       # export ranked hotspots -> codescene-hotspots-<id>.json
- `just mrva-pull`           # download the prebuilt CodeQL DBs (published under daemon-ai/daemon)
- `just mrva-scan <queries>` # run a CodeQL query pack across them + pretty-print

The CodeScene MCP is wired into Cursor via [.cursor/mcp.json](.cursor/mcp.json) ->
[scripts/cs-mcp](scripts/cs-mcp); agents should consult it (Code Health / hotspots) before and
after edits to avoid introducing technical debt. First entry into `.#review` builds the unfree
`codeql` (a ~1.6 GB GitHub download, not on `cache.nixos.org`); it is cached thereafter.

## Language specifics

See `daemon-node/AGENTS.md` (Rust) and `daemon-app/AGENTS.md` (C++/QML). Each submodule is its
own git repo and its AGENTS.md is self-contained for standalone checkouts.
