#!/usr/bin/env bash
# Superproject signed-commit gate (pre-push). The authoritative signing check: it
# cryptographically verifies (via `git verify-commit`) that EVERY commit being pushed is
# GPG-signed, rather than trusting a config value. Because it inspects real signatures it
# catches unsigned commits however they were produced — including `git commit --no-gpg-sign`
# and `-c commit.gpgsign=false`, which the pre-commit config check cannot see.
#
# Scoped to the superproject only: daemon-node / daemon-app intentionally do NOT sign
# (their local `commit.gpgsign=false` is repo convention). Installed by `just install-hooks`.
#
# NOTE: like every client hook this is skippable with `git push --no-verify`; AGENTS.md
# forbids that in the superproject, and the un-bypassable control is the origin's
# "require signed commits" branch protection. This hook is the fast local backstop.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"

# Superproject == the repo whose .gitmodules pins both children.
if ! { [ -f "$root/.gitmodules" ] \
       && grep -q 'daemon-node' "$root/.gitmodules" \
       && grep -q 'daemon-app'  "$root/.gitmodules"; }; then
  exit 0
fi

zero="$(git hash-object --stdin </dev/null | tr '0-9a-f' '0')"  # all-zero OID of the right length
fail=0

# stdin: <local_ref> <local_sha> <remote_ref> <remote_sha> per ref being pushed.
while read -r _local_ref local_sha _remote_ref remote_sha; do
  [ "$local_sha" = "$zero" ] && continue   # branch deletion — nothing to verify
  if [ "$remote_sha" = "$zero" ]; then
    # New remote ref: verify commits reachable from it but not from any existing remote.
    commits="$(git rev-list "$local_sha" --not --remotes)"
  else
    commits="$(git rev-list "${remote_sha}..${local_sha}")"
  fi

  for c in $commits; do
    if ! git verify-commit "$c" >/dev/null 2>&1; then
      echo "[pre-push] REFUSED: commit is not a valid GPG-signed commit:" >&2
      git --no-pager show -s --format='             %h  %s' "$c" >&2
      fail=1
    fi
  done
done

if [ "$fail" -ne 0 ]; then
  echo "[pre-push] The superproject requires every commit to be GPG-signed. Push aborted." >&2
  echo "[pre-push] Re-sign the offending commits (e.g. git rebase --exec 'git commit --amend --no-edit -S' <base>)" >&2
  exit 1
fi
