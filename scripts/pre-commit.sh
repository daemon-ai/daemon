#!/usr/bin/env bash
# Fast pre-commit gate, shared by all three daemon repos (super, daemon-node, daemon-app).
# Installed via `just install-hooks`. Runs the secret + spelling scan on staged files and a
# per-repo format check, all through the pinned Nix devShell so versions match CI. Heavy gates
# (clippy, clang-tidy, cargo-deny, sanitizers) stay out of the commit path - run `just lint`.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

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
