# AGENTS.md — daemon superproject

Nix-managed monorepo. Two independent submodules: `daemon-node` (Rust backend) and
`daemon-app` (Qt 6 GUI/TUI/WASM thin client). All tooling lives in Nix devShells — there are NO
host tools. Run everything via `just` (which wraps `nix develop`) or `nix develop --command ...`.

## Architecture invariant — the node decides, the apps render

`daemon-node` is the single authority for domain state, business logic, validation, persistence,
and orchestration. Every `daemon-app` surface (desktop GUI, TUI, WASM build) is a thin client of
the same wire contract: it renders node state and sends intents, and never re-derives or forks
domain behavior locally.

Features land node-first: extend the Rust types + `daemon-api.cddl` in `daemon-node`, run
`just update-codec`, then consume the new state from the app. If app code starts answering a
domain question itself instead of presenting the node's answer, the API is missing a capability —
add it to `daemon-node`. Inside `daemon-app`, UI is composed exclusively from the Daemon Kit
(`DaemonApp.Controls`) + `DaemonApp.Theme`, and GUI + TUI render one shared C++ view-model
layer — UI work that lands GUI-only without its TUI counterpart is incomplete (see
`daemon-app/AGENTS.md`).

## Before you call any change "done"

- `just lint`   # rustfmt + clippy (-D warnings) + clang-tidy + clang-format + qmllint + secrets + spell
- `just deny`   # dependency advisories / licenses / bans / sources
- Build + test what you touched: `just build-all`, and the relevant `just e2e` / per-repo tests.

Install the hooks once per clone: `just install-hooks` (pre-commit for all three repos, plus
the superproject-only pre-push signed-commit gate). Never bypass them (`git commit --no-verify`
and `git push --no-verify` are forbidden).

## Fast iteration loop (runtime verification, not a gate)

For edit→run cycles and user-feedback testing, do NOT rebuild the sealed bundle
(`nix run '.?submodules=1#bundled-app'`). Use the incremental dev loop, which reproduces the
bundled-app wiring from warm debug builds:

- `just dev-run` / `just dev-run-tui` # bundled-app experience in seconds (GUI / TUI)
- `just fresh-run`                    # dev-reset first: pristine first-run/onboarding state
- `just dev-reset`                    # stop managed daemons/workers, wipe app+node state and `.dev/`
                                      # (`DRY_RUN=1` to preview; `DEV_RESET_MODELS=1|all` for model state)

`just e2e` also runs against these incremental clients. None of this replaces the gates above —
`just bundle` remains the sealed parity check before calling release work done.

## Commit signing — superproject (non-negotiable)

Every commit in the **superproject** (this repo, the `.` bundle) MUST be GPG-signed. This is a
hard invariant, enforced in layers because a config value alone is not a gate:

- **Agents MUST NOT create any superproject commit without explicit, per-change human approval.**
  Do not commit here as a side effect of "finishing" work — propose the change and let the human
  commit (signed), or wait for an explicit "commit this" for the superproject specifically.
- **FORBIDDEN in the superproject** — never use any of these, and never instruct a subagent to:
  `-c commit.gpgsign=false`, `--no-gpg-sign`, `--no-verify` (commit or push), `commit.gpgsign=false`
  in any config scope, or any other means of disabling signing or skipping the hooks. If signing
  cannot happen (e.g. the hardware key is absent), the correct outcome is that the commit FAILS —
  do not route around it.
- **Enforcement layers**: `scripts/pre-commit.sh` refuses when signing is disabled for the commit;
  `scripts/pre-push.sh` cryptographically verifies (`git verify-commit`) every pushed commit is
  signed; and the origin's branch protection ("Require signed commits") is the authoritative,
  client-un-bypassable gate. The ultimate control is physical: the signing key lives on removable
  hardware, so with it detached no signed commit — hence no commit — can be produced.
- The child submodules (`daemon-node`, `daemon-app`) intentionally do **not** require signing
  (local `commit.gpgsign=false` is their convention). Do not "fix" that, and do not copy the
  superproject signing gate into them.

## Codec contract (do not edit generated code by hand)

The vendored C codec under `daemon-app/src/core/daemon/codec/{generated,vendor}` is generated
from the `daemon-node` CDDL contract.

- `just codec-drift`  # gate: vendored copy vs the pinned contract
- `just update-codec` # regenerate into the working tree after a contract change

## Versioning / releases (independent per-repo SemVer)

Each repo owns its own SemVer in a top-level `VERSION` file (the only file a human edits); the build
systems enrich it with a git build-metadata suffix (`X.Y.Z+<n>.g<hash>[.dirty]`, a bare `X.Y.Z` on a
clean tag). Bump through the recipes — never hand-edit the derived copies
(`daemon-node/Cargo.toml`, `daemon-app/packaging/UPDATES.json`).

- `just version`                    # print node / app / bundle versions (+ api/mux wire versions)
- `just set-version <repo> <X.Y.Z>` # write <repo>/VERSION and mechanically sync its mirrors
- `just check-version`              # gate (part of `just lint`): SemVer + node VERSION == Cargo version
- `just release <repo>`             # tag vX.Y.Z (clean tree + tag==VERSION + monotonic bump; DRY_RUN=1)

`<repo>` is `.` (the superproject bundle/product label), `daemon-node`, or `daemon-app`. The
submodule gitlinks pin the exact child commits a bundle ships; the wire protocol (`WireVersion`)
governs node↔app compatibility separately from these release versions.

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
