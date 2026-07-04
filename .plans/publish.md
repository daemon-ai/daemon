# Plan — hosted-node image publishing (dependency D4, second half)

**Agent:** WT2 · **Worktree:** `daemon-worktrees/daemon-image-publish` · **Branch:** `feat/hosted-node-publish`
**Charter:** wire the *publish* half of D4 — push the already-buildable `hosted-node-oci`
docker-archive to a registry and record the immutable **digest** that
`node_versions.image_ref` pins. Build half is done (`just build-image` → `result-image`).

Sources read: `docs/hosted-node-image.md` §2/§5, `flake.nix` (`hosted-node-oci` ~L312-335,
`devShells.default` L529-531), `justfile` (`build-image`, recipe conventions),
`daemon-api/docs/hosted-nodes.md` §8.1(5-6), §16, §18 row D4, `node_versions` DDL (§5, L354).

Scope reminder: superproject files only (`justfile`, `flake.nix` devShell, `docs/`, optional
CI). Submodules are unpopulated gitlinks here; build verification runs read-only against the
MAIN checkout or via `git submodule update --init`. No `git commit`/`git push`, no push to a
real registry (no creds exist).

---

## 1. Registry recommendation + naming

**Primary: GitHub Container Registry — `ghcr.io/<org>/daemon-hosted-node`.**

Rationale:
- The superproject already lives on GitHub (`daemon-ai/daemon`) and CI is GitHub Actions
  (`.github/workflows/ci.yml`). GHCR is the zero-new-vendor choice.
- Auth in CI is the built-in `GITHUB_TOKEN` with `permissions: packages: write` — **no new
  secret to provision**, which matters given "no credentials exist yet."
- Full OCI support incl. manifest digests (the contract), and layer sharing across pushes so
  the layered-image economics from §16 hold (weekly rollout moves only the daemon-binary layer).

**Fallback (documented): `registry.fly.io/<app>`.** The compute provider is Fly Machines, and
a machine can pull from Fly's own registry with no cross-registry credential (auth via
`fly auth docker` / a Fly deploy token → `REGISTRY_AUTH_FILE`). Downside: couples the image to
Fly and to a Fly app namespace; less general than GHCR for the "any provider referencing an OCI
ref" story in §8.1. Keep it as the escape hatch if GHCR pull-auth from Fly ever proves awkward.

**Naming / parameterization (no personal accounts hardcoded):**

| just var | default | meaning |
|---|---|---|
| `REGISTRY` | `ghcr.io` | registry host |
| `IMAGE_ORG` | `daemon-ai` | org/namespace (override for a personal/staging push) |
| `IMAGE_NAME` | `daemon-hosted-node` | repo name |

Resolved repo = `${REGISTRY}/${IMAGE_ORG}/${IMAGE_NAME}` e.g.
`ghcr.io/daemon-ai/daemon-hosted-node`. All three are `env_var_or_default(...)` just variables
**and** recipe parameters, so `just push-image REGISTRY=... IMAGE_ORG=...` or the env override
both work. Nothing personal is baked in; the default org is the project org, overridable.

**Tag = single source of truth from the artifact.** The flake already stamps the tag
(`bundleVersion` with `+`→`_`, raw version in the `org.opencontainers.image.version` label). The
recipe reads it *back out* of the built archive rather than re-deriving it in bash (which can't
reproduce `self.shortRev`): `skopeo inspect docker-archive:result-image | jq -r '.RepoTags[0]'`
→ take the part after the last `:`. This keeps the pushed tag byte-identical to what nix chose.
**Tags are labels; the digest is the contract** (§8.1.5) — the recipe pushes by tag then reads
the digest back.

---

## 2. `just` recipe(s) to add

A new `# --- publishing ---` section in the justfile. skopeo drives the push (see §4 on how it
enters the environment). Design notes:
- Uses `jq -r '.Digest'` to read the digest rather than `skopeo inspect --format '{{.Digest}}'`
  because Go-template `{{ }}` collides with just's own `{{ }}` interpolation inside recipes and
  needs ugly escaping; the two are equivalent and the docs will note it.
- Auth strictly from env (§3); never written to the tree.
- Records the pinnable ref to `dist/hosted-node-digest.txt` **and** stdout.

```make
# --- publishing (hosted-node image; docs/hosted-node-image.md §5) --------------------
# Push the built OCI docker-archive to a registry and record the immutable DIGEST that
# node_versions.image_ref pins (tags are labels; the digest is the contract, spec §8.1.5).
# Registry/repo are parameterized (no personal accounts); credentials come from env only,
# never stored: REGISTRY_USER + REGISTRY_PASSWORD (→ --dest-creds) or REGISTRY_AUTH_FILE
# (→ --authfile, e.g. a prior `skopeo login` or CI token). skopeo + jq come from the devShell.
REGISTRY   := env_var_or_default("REGISTRY", "ghcr.io")
IMAGE_ORG  := env_var_or_default("IMAGE_ORG", "daemon-ai")
IMAGE_NAME := env_var_or_default("IMAGE_NAME", "daemon-hosted-node")

# Build (if needed) then push result-image and record the digest.
# Usage: `just push-image` or `just push-image REGISTRY=... IMAGE_ORG=<you> IMAGE_NAME=...`.
# Optional: CHANNEL=canary appends a `-canary` tag suffix (see §16); REGISTRY_INSECURE=1 for a
# plain-HTTP registry (localhost dry-run).
push-image REGISTRY=REGISTRY IMAGE_ORG=IMAGE_ORG IMAGE_NAME=IMAGE_NAME: build-image
    #!/usr/bin/env bash
    set -euo pipefail
    repo="{{REGISTRY}}/{{IMAGE_ORG}}/{{IMAGE_NAME}}"
    # The tag nix stamped into the archive is the single source of truth (bundleVersion, +→_).
    base_tag="$(skopeo inspect docker-archive:result-image | jq -r '.RepoTags[0]')"
    base_tag="${base_tag##*:}"
    tag="$base_tag${CHANNEL:+-$CHANNEL}"
    dest="docker://${repo}:${tag}"
    auth=()
    [ -n "${REGISTRY_AUTH_FILE:-}" ] && auth+=(--authfile "$REGISTRY_AUTH_FILE")
    [ -n "${REGISTRY_USER:-}" ] && [ -n "${REGISTRY_PASSWORD:-}" ] \
      && auth+=(--dest-creds "${REGISTRY_USER}:${REGISTRY_PASSWORD}")
    tls=(); [ "${REGISTRY_INSECURE:-0}" = "1" ] && tls=(--dest-tls-verify=false)
    echo "push-image: copying result-image -> ${dest}"
    skopeo copy "${auth[@]}" "${tls[@]}" docker-archive:result-image "${dest}"
    # Read the registry manifest digest back (equivalent to --format '{{.Digest}}') and record it.
    idigest="$(skopeo inspect "${auth[@]}" "${tls[@]/--dest-/--}" "${dest}" | jq -r '.Digest')"
    ref="${repo}@${idigest}"
    mkdir -p dist
    printf '%s\n' "$ref" > dist/hosted-node-digest.txt
    echo "push-image: pushed  ${repo}:${tag}"
    echo "push-image: image_ref = ${ref}"
    echo "push-image: recorded -> dist/hosted-node-digest.txt   (paste into node_versions API)"
```

Plus a **credential-free local proof recipe** (§4) that exercises the identical push→digest path
against a throwaway registry:

```make
# Local dry-run: prove the whole push→digest pipeline offline (no real registry, no creds).
# Spins up a throwaway `registry:2` under podman on 127.0.0.1:5000, runs `push-image` against it
# insecure, prints the recorded digest, then tears the registry down. Also usable with an
# `oci:` layout target for a zero-daemon smoke (see docs §5).
verify-push: build-image
    #!/usr/bin/env bash
    set -euo pipefail
    port=5000; name=hosted-node-registry-dryrun
    podman run -d --rm --name "$name" -p "127.0.0.1:${port}:5000" registry:2 >/dev/null
    trap 'podman stop "$name" >/dev/null 2>&1 || true' EXIT
    for _ in $(seq 30); do curl -sf "http://127.0.0.1:${port}/v2/" >/dev/null && break; sleep 0.2; done
    REGISTRY="127.0.0.1:${port}" IMAGE_ORG=dryrun REGISTRY_INSECURE=1 \
      just push-image
    echo "verify-push: OK — digest recorded in dist/hosted-node-digest.txt"
    cat dist/hosted-node-digest.txt
```

(Decision: recording contract is `dist/hosted-node-digest.txt` holding the full pinnable
`repo@sha256:...` ref, plus the same line on stdout. `dist/` gets a `.gitignore` entry.)

---

## 3. Credentials — how supplied, never stored

- **Local/interactive:** `export REGISTRY_USER=... REGISTRY_PASSWORD=...` (a GHCR PAT with
  `write:packages`) before `just push-image`; skopeo receives them via `--dest-creds`. Or run
  `skopeo login ghcr.io` once and pass the resulting file via `REGISTRY_AUTH_FILE`.
- **CI:** `--dest-creds "${{ github.actor }}:${{ secrets.GITHUB_TOKEN }}"` with
  `permissions: { packages: write }` — GitHub-issued, scoped, no stored secret.
- **Never in tree:** creds live only in the process env / an authfile outside the repo. `.env`
  is already git-ignored; `dist/` will be added to `.gitignore`. No credential is baked into a
  nix store path or a committed file.

---

## 4. How skopeo enters the environment

The `devShells.default` currently ships **only `pkgs.just`** (flake.nix L529-531); there is no
skopeo/jq anywhere in the flake. The justfile convention is "tools come from the pinned Nix
devShells." So:

- **Add `pkgs.skopeo` and `pkgs.jq` to `devShells.default`** (one-line `packages` edit). This
  pins both to the flake's nixpkgs (reproducible, matches the convention) and makes them
  available under `nix develop` and to CI via `nix develop --command just push-image`.
- Documented fallback for ad-hoc use without entering the shell:
  `nix run nixpkgs#skopeo -- ...` (not pinned to the flake — fine for a one-off, not for CI).

skopeo copies straight from the `dockerTools.buildLayeredImage` output:
`docker-archive:result-image` is the exact transport skopeo reads (that output is a
`docker save`-shaped tarball). No podman/daemon needed for the real push.

---

## 5. Dry-run verification strategy (no registry creds)

Two offline proofs, strongest first:

1. **Throwaway localhost registry (`just verify-push`).** Runs `registry:2` under rootless
   podman (already the smoke-test runtime, §4 of the image doc), pushes insecure, and reads the
   digest **back from the registry** — exercising the *exact* `docker://` push + digest-read path
   `push-image` uses in production, minus real creds. This is the primary evidence.
2. **`oci:` layout copy (zero dependencies).**
   `skopeo copy docker-archive:result-image oci:dist/oci-layout:<tag>` then
   `skopeo inspect oci:dist/oci-layout:<tag> | jq -r '.Digest'` — no daemon, no network, no
   creds. Proves the archive is valid OCI and yields a digest. Documented as the fallback proof
   for environments without podman.

Both produce a `dist/hosted-node-digest.txt`; the transcript (recipe output + the digest file)
is the "local verification evidence" deliverable. Build verification of `result-image` itself
runs read-only against the MAIN checkout (`cd /home/j/experiments/daemon && nix build
'.?submodules=1#hosted-node-oci' --no-link --print-out-paths`) or via `git submodule update
--init` inside this worktree — never editing submodule trees.

Caveat: the registry *manifest digest* is registry-specific (media-type conversions can differ
between a localhost `registry:2` and GHCR), so the digest from a dry-run is a pipeline proof, not
the value that ends up in `node_versions` — that comes from the real GHCR push. Documented.

---

## 6. Docs changes

Rewrite `docs/hosted-node-image.md` **§5** from "Publishing (D4's second half, not wired here)"
to an **as-built runbook**:
- Prereqs: `nix develop` (now provides skopeo + jq).
- Registry choice + rationale (GHCR primary, Fly fallback), the `REGISTRY`/`IMAGE_ORG`/
  `IMAGE_NAME` knobs.
- The operator flow, end to end:
  1. `just build-image`
  2. `export REGISTRY_USER=… REGISTRY_PASSWORD=…`
  3. `just push-image` (or with overrides)
  4. copy the `repo@sha256:…` from `dist/hosted-node-digest.txt` / stdout
  5. **paste the digest into the hosting admin `node_versions` API (daemon-api side) as
     `image_ref`** (channel `stable`|`canary`, `wire_version` admin-entered per §16).
- The credential-free dry-run (`just verify-push` and the `oci:` alternative).
- Canary convention (§16 below), and the x86_64-only / manifest-list note (Q9).
- Update §9 open-question item 7 ("Image publishing pipeline") to point at the now-wired recipe.

The daemon-api spec is **read-only** and not edited; it already documents the operator side
(§16, §8.1). I'll cross-reference it, not modify it.

---

## 7. Canary channel convention (recommendation)

`node_versions.channel` is `stable | canary` (a DB column, §5 DDL / §16). **Recommend: same repo,
`-canary` tag suffix** (`push-image CHANNEL=canary` → `…:<version>-canary`) rather than a
separate `daemon-hosted-node-canary` repo. Reasons:
- The digest is the real contract; channel is a `node_versions` row attribute, not something
  derived from the image. The suffix is purely a human-readable convenience on an otherwise
  identical artifact.
- Same repo = shared blob store = canary and stable share layers (cheap; matches §16 economics).
- One repo = one set of registry permissions, simpler CI.

Operationally: push once, record the digest, create a `channel='canary'` `node_versions` row;
promotion to stable is a daemon-api DB action (`canary`→`stable`, §16 / §12), **no re-push** —
the same digest is promoted. Documented so admins don't rebuild to promote.

---

## 8. Optional CI sketch (no real secrets)

Only if trivial: a `publish-image` job sketch in `.github/workflows/ci.yml` (or a separate
`publish.yml`), **commented / guarded, not wired to real secrets**:
- Trigger: `on: push: tags: ['v*']` (or `workflow_dispatch`).
- Steps: checkout `submodules: recursive` → nix installer + magic-nix-cache (matching existing
  jobs) → `nix develop --command just push-image` with
  `REGISTRY_USER=${{ github.actor }}` / `REGISTRY_PASSWORD=${{ secrets.GITHUB_TOKEN }}` and
  `permissions: { contents: read, packages: write }` → upload `dist/hosted-node-digest.txt` as a
  build artifact (so an admin can grab the digest to paste into `node_versions`).
- Kept as a sketch: I will NOT enable it against real infra; digest→`node_versions` stays a
  human/admin step (spec §16: "published by admins").

---

## 9. Risks / caveats

- **Registry-specific digest.** The manifest digest depends on the registry's media-type
  handling; `image_ref` must include the registry host and is not portable across registries.
  Dry-run digests ≠ the eventual GHCR digest (pipeline proof only). Documented.
- **skopeo not yet in the flake.** Requires the `devShells.default` edit; without it the recipe
  fails fast (or must use the `nix run nixpkgs#skopeo` fallback). Low risk, one-line change.
- **Tag re-derivation.** Avoided by reading the tag from the archive; no bash duplication of
  `self.shortRev` logic.
- **`{{ }}` escaping.** Using `jq -r '.Digest'` instead of `--format '{{.Digest}}'` sidesteps
  just interpolation clashes; documented as equivalent.
- **Multi-arch.** Build is per-system (x86_64 today). v1 pushes x86_64-only (Fly is x86_64-first,
  Q9); a manifest list is a later `push-image` extension (`skopeo copy --all` / `--multi-arch`),
  called out but not built.
- **Overwritable tags.** GHCR allows moving a tag; this is exactly why the contract pins the
  immutable digest, not the tag.
- **podman/`registry:2` in dry-run** needs to pull `registry:2` (network) on first run; the
  `oci:` layout proof is the offline fallback that needs neither podman nor network.
- **No real push this turn.** Everything is verified locally/dry-run; the first real GHCR push
  waits on provisioned credentials (out of scope, no creds exist).

---

## 10. Deliverables checklist (implementation phase, post-approval)

1. `justfile`: `push-image` (parameterized, env creds, digest → `dist/hosted-node-digest.txt` +
   stdout) and `verify-push` (offline proof).
2. `flake.nix`: add `pkgs.skopeo` + `pkgs.jq` to `devShells.default`.
3. `.gitignore`: add `/dist/`.
4. `docs/hosted-node-image.md`: §5 rewritten to the as-built runbook (+ §9 item 7 update),
   canary convention, arch note, operator flow ending at the `node_versions` API.
5. Local verification evidence: `just verify-push` transcript + `dist/hosted-node-digest.txt`.
6. (Stretch) commented CI `publish-image` job sketch, no real secrets.

## 11. Open questions for the approver

1. Default `IMAGE_ORG` — is `daemon-ai` (the GitHub org) the right default, or prefer an
   explicit placeholder that forces an override?
2. GHCR primary vs Fly registry primary — I recommend GHCR; confirm the compute-adjacency of
   `registry.fly.io` isn't preferred for launch.
3. Canary via tag suffix (recommended) vs separate repo — confirm.
4. Is the CI sketch wanted this round, or deferred until credentials/secrets exist?
