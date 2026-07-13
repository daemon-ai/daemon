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

- `just lint`   # DIFF-SCOPED: rustfmt + clippy (-D warnings) + clang-tidy + clang-format +
                # qmllint + secrets + spell over what changed vs origin/master (LINT_BASE overrides)
- `just deny`   # dependency advisories / licenses / bans / sources
- Build + test what you touched: `just build-all`, and the relevant `just e2e` / per-repo tests.

Install the hooks once per clone: `just install-hooks` (pre-commit for all three repos, plus
the superproject-only pre-push signed-commit gate). Never bypass them (`git commit --no-verify`
and `git push --no-verify` are forbidden).

## Resource discipline (non-negotiable — a violation has hard-crashed the host before)

Committed history has already been gated; only the delta ever needs re-checking. An unbounded
gate is not "thorough", it is an outage: a whole-tree clippy + clang-tidy at `-P$(nproc)` stacked
with nix builds has thrashed this machine into swap and forced a hard reboot.

- **Never run `just lint-all`** (or hand-rolled whole-tree clippy / clang-tidy sweeps) as an agent
  or in CI. It exists for a human's explicit pre-release / post-rebase pass only. `just lint` is
  diff-scoped and is the gate.
- **Cap every build.** The lint recipes default to half the cores (`LINT_JOBS`); match that
  discipline everywhere else: `cargo … -j N` / `CARGO_BUILD_JOBS=N`, `cmake --build -j N`,
  `nix build --max-jobs 1 --cores N` with N ≤ nproc/2. Never bare `-j`/`-P$(nproc)`.
- **One build at a time.** Never stack a `nix build` with a cargo/cmake build or another
  `nix build`. Iterate in the devShells (warm incremental builds); sealed `nix build` package
  lanes run at most once, at the end — or are left to hosted CI.
- **Kills must be verified.** Killing a `nix build` client does NOT reliably stop daemon-side
  builders. After a kill, confirm with `pgrep -f 'cc1plus|rustc|makensis|ninja'` that compilation
  actually stopped before starting anything else.
- **Keep cargo's target dir repo-local.** The daemon-node devShell repins a tmp-located
  `CARGO_TARGET_DIR` (agent-sandbox cache redirects) to `<checkout>/target`; without that, every
  invocation cold-builds the whole workspace. Don't route cargo around the devShell.

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

## Driving the GUI over accessibility (kwin-mcp)

`kwin-mcp` (the Nix-packaged `.#kwin-mcp` server, launched via `scripts/kwin-mcp`) drives the real
GUI through the AT-SPI accessibility tree the `daemon-app` annotations expose — for eyeballing a
build or scripting agent GUI journeys. It runs the client in an isolated virtual KWin session
(`session_start`, headless) or against the live desktop (`session_connect`, visible). Input is
delivered through AT-SPI actions, not synthetic pointer/key events (`KWIN_MCP_INPUT_BACKEND=atspi`,
set by the launcher). Requires KDE Plasma 6 / KWin on the host.

Drive the **dynamic-Qt** client — it carries the accessibility bridge. The sealed static bundle
(`bundled-app`) has no AT-SPI bridge (and doesn't render under a bare launch), so it is not the
automation target; use `daemon-app#default`, which runs the same daemon-service experience:

```
nix build ./daemon-app#default --out-link result-app     # -> result-app/bin/daemon-app
```

Tool flow: `session_start` | `session_connect` -> `launch_app` -> `find_ui_elements` /
`accessibility_tree` / `mouse_click` / `keyboard_type` / `screenshot` -> `session_stop`. The
`launch_app` env selects the runtime:

- Always: `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 QT_ACCESSIBILITY=1`, and a throwaway
  `HOME` + `XDG_{CONFIG,DATA,CACHE,STATE}_HOME` so it never touches a real profile.
- Mock (hermetic, no node — deterministic GUI/a11y checks): `DAEMON_APP_SERVICE_MODE=mock`, and
  seed the temp `HOME`'s `.config/daemon-app/daemon-app.conf` with `[app] setupComplete=true` and
  `[conn] mode=mock target=ready` to land in the main shell (omit the seed for the mock first-run).
- Daemon service (real co-packaged node — first-run wizard, integration smoke):
  `DAEMON_APP_SERVICE_MODE=daemon`, `DAEMON_BIN=<a built daemon binary>` (e.g. from
  `nix build '.?submodules=1#bundled-app'` or a `daemon-node` debug build) and optionally
  `DAEMON_INFER__WORKER_BIN=<worker>`; a fresh temp `HOME` boots into the connection wizard.

If an AT-SPI query reports "couldn't connect to accessibility bus", the session's a11y bus socket
went stale — `systemctl --user restart at-spi-dbus-bus.service`.

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

**Agents MUST NOT bump or otherwise change any version unless the human explicitly asks for a
version bump.** That covers every `VERSION` file, `just set-version`, `just release`, and the
derived mirrors — in all three repos. Landing a feature is NEVER an implicit reason to bump;
"finishing" work does not include versioning it. If a change seems to warrant a bump (e.g. a wire
or packaging change), say so in your summary and let the human decide.

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
