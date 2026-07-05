#!/usr/bin/env bash
# Fast pre-commit gate, shared by all three daemon repos (super, daemon-node, daemon-app).
# Installed via `just install-hooks`. Runs the secret + spelling scan on staged files and a
# per-repo format check, all through the pinned Nix devShell so versions match CI. Heavy gates
# (clippy, clang-tidy, cargo-deny, sanitizers) stay out of the commit path - run `just lint`.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

# --- Superproject signing gate (commit-time backstop) --------------------------------------
# The superproject requires EVERY commit to be GPG-signed. Refuse here if signing is disabled
# for THIS commit. `git -c commit.gpgsign=false` — the exact circumvention this closes —
# propagates into hooks via GIT_CONFIG_PARAMETERS, so `git config --bool commit.gpgsign` reads
# the effective (overridden) value and catches it. This does NOT see `git commit --no-gpg-sign`
# (a runtime flag, not config) nor `--no-verify` (skips the hook entirely) — those are caught
# cryptographically by scripts/pre-push.sh and, definitively, by the origin's require-signed-
# commits branch protection. Superproject only: daemon-node/daemon-app do not sign by convention.
if [ -f "$root/.gitmodules" ] \
   && grep -q 'daemon-node' "$root/.gitmodules" \
   && grep -q 'daemon-app'  "$root/.gitmodules"; then
  if [ "$(git config --bool commit.gpgsign 2>/dev/null || echo false)" != "true" ]; then
    echo "[pre-commit] REFUSED: superproject commits MUST be GPG-signed, but commit.gpgsign is" >&2
    echo "             not 'true' for this commit (someone passed -c commit.gpgsign=false, or it" >&2
    echo "             is unset). Re-run without disabling signing. Do NOT use --no-gpg-sign or" >&2
    echo "             --no-verify to route around this." >&2
    exit 1
  fi
fi

# Staged, added/copied/modified files only (deletes/renames-away excluded).
mapfile -t FILES < <(git diff --cached --name-only --diff-filter=ACM)
[ "${#FILES[@]}" -eq 0 ] && exit 0

# Pick the devShell that ships the tools this repo needs. Each repo's own shell has
# gitleaks+typos; daemon-node adds rustfmt, daemon-app adds clang-format.
if [ -f "$root/Cargo.toml" ] && grep -q '^\[workspace\]' "$root/Cargo.toml"; then
  FLAKE="$root"; LANG_KIND=rust
elif [ -f "$root/CMakeLists.txt" ]; then
  FLAKE="$root"; LANG_KIND=cpp
else
  FLAKE="$root/daemon-node"; LANG_KIND=none   # superproject: docs/justfile/yaml -> secrets+spell
fi

export LANG_KIND
printf '%s\n' "${FILES[@]}" | nix develop "$FLAKE" --command bash -euo pipefail -c '
  mapfile -t files

  echo "[pre-commit] gitleaks (staged)…"
  gitleaks protect --staged --no-banner --redact

  echo "[pre-commit] typos…"
  printf "%s\n" "${files[@]}" | xargs -r typos --

  case "$LANG_KIND" in
    rust)
      mapfile -t rs < <(printf "%s\n" "${files[@]}" | grep "\.rs$" || true)
      if [ "${#rs[@]}" -gt 0 ]; then
        echo "[pre-commit] rustfmt…"
        printf "%s\n" "${rs[@]}" | xargs -r rustfmt --check --edition 2021
      fi ;;
    cpp)
      mapfile -t cc < <(printf "%s\n" "${files[@]}" | grep -E "\.(cpp|h)$" || true)
      if [ "${#cc[@]}" -gt 0 ]; then
        echo "[pre-commit] clang-format…"
        printf "%s\n" "${cc[@]}" | xargs -r clang-format --dry-run --Werror
      fi ;;
  esac
'
echo "[pre-commit] ok"
