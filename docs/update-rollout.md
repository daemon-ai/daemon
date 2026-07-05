# Update rollout specification

**Scope:** the end-to-end *process* of shipping an update to the installed fleet — versioning,
cutting a release, what CI builds/signs/publishes, how clients pick it up, per-platform rollout
duties, and the emergency levers. This is the operator-facing companion to the *system*
specification in `daemon-app/packaging/UPDATES.md` (capability dial, manifest schema, verification,
downloader, `daemon-updater` helper, threat model). When this document says "the client does X",
the authoritative definition of X lives there and in `daemon-app/src/core/update/`.

**Sources of truth (read alongside):**

| Concern | Where |
|---|---|
| Client mechanics, schema, threat model | `daemon-app/packaging/UPDATES.md` |
| Release pipeline (implementation) | `.github/workflows/release.yml` |
| Feed generator + signer | `daemon-app/scripts/release-manifest.sh` |
| Version bump / tag machinery | `justfile` (`set-version`, `release`, `check-version`), `scripts/release.sh` |
| Windows validation runbook | `daemon-app/packaging/windows/UPDATE-VALIDATION.md` |
| macOS build/sign/E2E runbook | `daemon-app/packaging/macos/README.md` |

---

## 1. The delivery system in one page

Every desktop build of `daemon-app` polls a single signed feed:

```
https://github.com/daemon-ai/daemon/releases/latest/download/manifest.json   (+ .minisig)
```

- **`releases/latest`** is GitHub's pointer to the most recent non-prerelease, non-draft release
  of `daemon-ai/daemon`. Publishing a release *is* the rollout; there is no separate deploy step.
- The manifest is signed (minisign/Ed25519) with the key held **only** in the `daemon-ai/daemon`
  CI secret store (`MINISIGN_SECRET_KEY`). Clients pin the public key at compile time and reject
  anything unverifiable — hosting is untrusted by construction.
- Each artifact row carries an `updateCapability` dial; the client computes
  **effective = min(compiled dial, feed dial)**. The feed can *lower* a fleet's behavior
  (kill-switch) but can never raise what a shipped binary may do.
- Clients check ~15 s after launch and then daily (ETag-conditional; auto-check is a user
  toggle, default on; manual "check now" always works). An update surfaces as a banner; the
  action is **"Install & restart"** on SelfApply platforms and **"Open"**/notes-link otherwise.
- Only **upgrades** are ever offered (strict SemVer monotonicity). The feed cannot downgrade
  the fleet — a bad release is fixed *forward* (see §5.2).

What ships today, per artifact (full rationale in `UPDATES.md`):

| Artifact | Effective capability | Applied by |
|---|---|---|
| AppImage (linux x86_64) | **SelfApply** | `daemon-updater` rename-swap over `$APPIMAGE`, relaunch |
| deb / rpm | Notify | user + package manager (banner + notes link only) |
| portable tar | Notify | user unpacks manually |
| NSIS `.exe` (windows x86_64) | **SelfApply** | `daemon-updater` runs installer `/S` (per-user), relaunch |
| DMG `.app` (macos aarch64) | **SelfApply** | `daemon-updater` two-move bundle swap, relaunch |
| APK (android, sideload) | None (inert) | out of band; no TLS in the Qt Android build yet |
| WASM | None (not in feed) | served by the node; browser owns delivery (§4) |

---

## 2. Versioning contract

Three independent SemVer `VERSION` files exist (per `AGENTS.md`): `./VERSION` (the **bundle** —
the product label a release tag is cut from), `daemon-app/VERSION` (compiled into the app as its
`currentVersion`), and `daemon-node/VERSION` (rides inside the bundle; not part of the update
feed). The update system sees two of them, in different places:

- the **manifest `version`** is the *bundle* version: `release.yml` reads `./VERSION` and the tag
  must match it (`vX.Y.Z` == `VERSION`, enforced by the publish job and by `scripts/release.sh`);
- the **client's comparison version** is the *app* version: `DAEMON_APP_VERSION_STR` derives from
  `daemon-app/VERSION` (+ git build metadata, stripped before comparison);
- **macOS staged verification** compares the staged bundle's `CFBundleShortVersionString`
  (= `daemon-app/VERSION` at build time) against the manifest `version` and degrades SelfApply to
  DownloadAndOpen on mismatch;
- **artifact filenames** carry `daemon-app/VERSION` (CPack `PROJECT_VERSION`:
  `daemon-0.1.0-linux-x86_64.AppImage`, `daemon-0.1.0-win64.exe`, `daemon-0.1.0-macos-arm64.dmg`,
  `daemon_0.1.0_amd64.deb`, `daemon-0.1.0-1.x86_64.rpm`), except the renames `release.yml`
  applies with the bundle version (`daemon-portable-<v>-x86_64.tar.zst`,
  `daemon-app-<v>-android-arm64-v8a-debug.apk`, `daemon-app-<v>-wasm.tar.gz`).

That yields the two **hard invariants for any public release**:

1. **Alignment:** `daemon-app/VERSION` == `./VERSION` at the release commit. Otherwise the feed
   advertises a version the binaries don't carry: the SemVer gate mis-compares, and macOS
   staged verification refuses the swap. Bump them together
   (`just set-version daemon-app X.Y.Z && just set-version . X.Y.Z`).
2. **Monotonicity:** the new version is strictly greater than the last *published* feed version
   (and than every app version previously shipped — implied by alignment + history).
   `scripts/release.sh` enforces a bump over the latest existing `vX.Y.Z` tag.

> **State at the time of writing:** the bundle is `0.0.1` while daemon-app is `0.1.0` — they have
> never been aligned because no public feed release has been cut yet. The first real rollout must
> start by aligning both to something `> 0.1.0` (e.g. `0.1.1` or `0.2.0`).

`daemon-node/VERSION` moves on its own cadence; desktop bundles ship app + node together so the
pair is internally consistent by construction. Wire compatibility (`WireVersion`) only matters for
apps talking to *remote/hosted* nodes and is governed independently of release versions.

Channel is **`stable`** and single today. The channel id is compiled into clients
(`DAEMON_APP_UPDATE_CHANNEL`, default `stable`), recorded in the manifest, and pinned by the
signature's trusted comment (`daemon <channel> <version>`) — see §6.1 before adding one.

---

## 3. Standard rollout procedure

### 3.1 Preflight (release commit)

On a clean `master` with submodule gitlinks pointing at the child commits to ship:

1. Gates: `just lint`, `just deny`, `just build-all`, plus the relevant `just e2e` suites.
2. Updater-touching changes only: run the updater E2Es —
   `nix run ./daemon-app#updater-appimage-e2e` (Linux), the macOS E2E on the M1
   (`packaging/macos/e2e-selfapply.sh`), and the Windows runbook at whatever depth the change
   warrants (`packaging/windows/UPDATE-VALIDATION.md`).
3. Bump versions (invariant 1): `just set-version daemon-app X.Y.Z` (also syncs the legacy
   `packaging/UPDATES.json` mirror), commit + push daemon-app, then in the superproject
   `just set-version . X.Y.Z`, bump the gitlink(s), commit.
4. `just check-version` (also part of `just lint`) must pass.

### 3.2 Tag and push

```sh
just release .          # validates SemVer/clean-tree/tag==vVERSION/monotonic, cuts vX.Y.Z
git push origin master vX.Y.Z
```

`DRY_RUN=1 just release .` previews. A prerelease tag (e.g. `v0.2.0-rc.1`) may be cut manually:
the pipeline accepts it (tag *core* must still equal `VERSION`) and publishes it as a GitHub
**prerelease**, which `releases/latest` ignores — the stable fleet never sees it. That is the
supported way to stage a release candidate end-to-end without rolling it out.

### 3.3 What CI does (`.github/workflows/release.yml`)

The tag push triggers four build jobs and a publish job (`workflow_dispatch` runs builds +
manifest for validation but skips the GitHub Release):

1. **linux** — `nix build .?submodules=1#package-linux` + `#package-portable-tarball`. deb / rpm /
   AppImage keep their CPack names (their `.sha256` / `.zsync` sidecars reference those exact
   names); the portable tarball is renamed with the bundle version, keeping the `x86_64` token.
2. **windows** — `#package-nsis`, MinGW cross build; no Windows runner.
3. **android-wasm** — `daemon-app#apk` (debug-signed by design) + `daemon-app#wasm` (tarred;
   deliberately excluded from the feed).
4. **macos** — **disabled by default** (repo variable `ENABLE_MACOS_RELEASE`, currently unset;
   the job body is not wired). Until it is enabled, macOS artifacts are attached manually — §3.4.
5. **publish** — downloads all dist artifacts, verifies **tag core == `VERSION`**, then:
   - materializes `MINISIGN_SECRET_KEY` into a runner-temp keyfile (umask 077, deleted after) and
     runs `release-manifest.sh dist <version> stable --notes-url <release page>`, which discovers
     artifacts by filename, records `size`/`sha256`/`arch`, consumes `.glibc`/`.zsync` sidecars,
     emits the per-kind capability rows, and writes `manifest.json` + detached
     `manifest.json.minisig` (trusted comment `daemon stable <version>`);
   - writes `SHA256SUMS` over everything staged (manifest + sig included);
   - `gh release create vX.Y.Z dist/* --verify-tag --generate-notes` (`--prerelease` when the tag
     carries a `-` suffix).

Publishing the release atomically moves `releases/latest` — from that moment the fleet's next
poll sees the new manifest. All `file`/`zsync` fields are bare names resolved relative to the
manifest's own (post-redirect) URL, so manifest and artifacts **must live on the same release**
— which `gh release create dist/*` guarantees.

Notes on sidecars: the AppImage build emits `.sha256` and `.zsync`; a `.glibc` floor sidecar is
not currently emitted, so today's manifests omit `glibcFloor` (the client then applies no glibc
gate — acceptable while the floor is stable at app 2.38 / node 2.39; wire the sidecar before the
floor ever rises).

### 3.4 macOS lane (manual until `ENABLE_MACOS_RELEASE` is wired)

On the mac host (M1): `just package-dmg`, then attach to the same release and re-sign the feed —
a **late artifact attach**, which is only legitimate for adding rows, never for changing bits:

```sh
gh release download vX.Y.Z -D dist                # existing assets incl. manifest
cp result-package-dmg/daemon-<v>-macos-arm64.dmg[.sha256] dist/
rm dist/manifest.json* dist/SHA256SUMS            # stale: both get regenerated below
MINISIGN_SECRET_KEY_FILE=... \
  bash daemon-app/scripts/release-manifest.sh dist <version> stable --notes-url <release page>
( cd dist && sha256sum -- * > ../SHA256SUMS && mv ../SHA256SUMS . )
gh release upload vX.Y.Z dist/daemon-*-macos-arm64.dmg* dist/manifest.json* dist/SHA256SUMS --clobber
```

Replacing `manifest.json` changes its ETag, so already-polled clients pick the extended manifest
up on their next check. Do this promptly after publish — between publish and re-upload, macOS
clients see a manifest without a dmg row and cap at Notify (notes link), which is safe but
user-visible. Once the macOS CI job is enabled (build `package-dmg`, stage `.dmg` + `.sha256`,
add `macos` to the publish job's `needs`), this section collapses into §3.3.

### 3.5 Post-publish verification (always, before walking away)

```sh
curl -sLo /tmp/m.json      https://github.com/daemon-ai/daemon/releases/latest/download/manifest.json
curl -sLo /tmp/m.json.minisig https://github.com/daemon-ai/daemon/releases/latest/download/manifest.json.minisig
printf '%s\n' 'untrusted comment: daemon release feed' \
  'RWRXpowS90Fy+TYhRsrBbQNSDvjbtJpqi9T89OGqSNTLkOa5vn62hK0o' > /tmp/release.pub
bash daemon-app/scripts/release-manifest.sh --verify /tmp/m.json /tmp/release.pub
jq '.version, [.artifacts[] | {kind, arch, file, updateCapability}]' /tmp/m.json
```

Checklist: signature verifies with the **production** pin; trusted comment says
`daemon stable <version>`; every intended row present with the intended capability; `sha256`s
match `SHA256SUMS`. Then prove one live offer: run the *previous* release's build of a SelfApply
platform and confirm banner → Install & restart → relaunched at the new version. (For a
no-publish rehearsal, use the E2E harness levers — `DAEMON_APP_UPDATE_FEED_URL_OVERRIDE` et al.,
`UPDATES.md` §"Environment / test levers" — never a production build pointed at a test feed.)

### 3.6 Fleet uptake — what users experience

No push channel exists; uptake is poll-driven: each install notices on its next launch (~15 s
in) or next daily check, modulo the auto-check toggle and per-version dismissal. Expect the fleet
to converge over ~a day of active use, not minutes. SelfApply platforms: banner → one click →
verified download (resumable) → atomic swap → relaunch into the new version; any precondition
failure degrades to DownloadAndOpen with a visible reason, never a dead end. Notify platforms:
banner + release-notes link only. The TUI surfaces notify-parity (no apply button yet).

---

## 4. Platform specifics (rollout view)

**AppImage — SelfApply.** The flagship self-update path; covered by the Nix E2E
(`updater-appimage-e2e`), which any updater-adjacent change must keep green. The published
`.zsync` sidecar + the embedded `gh-releases-zsync` line serve external `AppImageUpdate` users;
the in-client downloader fetches whole files (delta transport is future work). Users who
installed via deb/rpm/tar are *not* reached by SelfApply even though all four share one binary —
the feed rows pin them to Notify (`min()` does the rest).

**deb / rpm — Notify.** The banner links the release notes; users re-install by hand. Replacement
belongs to the package manager; these stay Notify until a proper apt/dnf repo channel exists
(future work). Nothing to operate per release beyond publishing the assets.

**Portable tar — Notify.** Unpack location is unknown to the app; users replace manually.

**Windows NSIS — SelfApply.** Per-user install (`%LOCALAPPDATA%\Programs\Daemon`, HKCU, zero
UAC), which is what makes the silent `/S` self-apply promptless. There is no Windows CI runner
and wine is unreliable for the installer: after any change to the installer, helper, or apply
path, run `packaging/windows/UPDATE-VALIDATION.md` on a real Windows machine (Depth 1 minimum;
Depth 2 for updater-core changes) before tagging. Binaries are unsigned (no Authenticode);
SmartScreen friction on first download is expected until code signing lands
(`daemon-app/packaging/windows/README.md` documents the `osslsigncode` path).

**macOS DMG — SelfApply.** Ad-hoc signed; validated E2E on the M1. Updates relaunch cleanly
through Gatekeeper on the machine that performed them; the *first manual install* of an ad-hoc
build still needs right-click-Open. Guards (translocation, read-only volume, unwritable
`/Applications`, cross-filesystem staging) degrade to DownloadAndOpen before any mutation. Until
notarization + Developer ID signing land (future work), keep the manual attach lane of §3.4 and
re-run `packaging/macos/e2e-selfapply.sh` for updater-adjacent changes.

**Android APK — None (inert).** Sideload artifact, debug-signed by design; the compiled dial is
unset (no feed fetch, no UI) because the Qt Android build ships no TLS stack. Rolling out to
Android means publishing the new APK asset and telling users out of band. Revisit the dial when
Android TLS lands; a store listing would own its own updates regardless.

**WASM — None (not in the feed).** The browser bundle rides the release as an asset but is
excluded from the manifest; delivery is the serving node's concern. "Updating" WASM users =
updating the node deployment that serves it (see `docs/hosted-node-image.md`): rebuild + push the
hosted-node image, promote its digest via `node_versions`; browsers pick it up on reload.

---

## 5. Emergency procedures

### 5.1 Kill-switch: lower a capability without shipping binaries

The feed dial can lower but never raise. To stop a misbehaving self-apply fleet-wide: download
the current release's assets, regenerate the manifest, edit the offending rows'
`updateCapability` down (`SelfApply` → `Notify`), re-sign, `gh release upload --clobber` onto the
**same release** (same version — this changes behavior, not the offer). Clients re-fetch on their
next poll (ETag change) and cap themselves. Note `release-manifest.sh` has no capability
override flag: edit the emitted JSON before signing (`jq` in place), or sign a hand-edited
manifest with `minisign -S … -t "daemon stable <version>"`. The signature is over the exact
bytes; the trusted comment must keep the same channel/version.

### 5.2 A bad release is out

- **Contain:** if the defect is in the *apply* path, kill-switch it (§5.1). If the defect is in
  the app itself, deleting the GitHub release rolls `releases/latest` back to the previous good
  release — new polls then see the *older* manifest, which clients ignore (monotonicity), and new
  manual downloads get the good version.
- **Remediate: fix forward.** Clients never downgrade; ship `X.Y.Z+1` through the standard
  procedure. Users who already updated to the bad build get the fix on their next poll.

### 5.3 Key rotation / compromise

Planned rotation (per `UPDATES.md`): cut a release **signed with the old key** whose binaries pin
the **new** public key — update the pin in `daemon-app/nix/portable.nix`, `nix/windows.nix`, and
`daemon-app/flake.nix` (`mkDarwinArtifacts`), plus the documented pin in `UPDATES.md`
(§Verification) and the verify snippet in §3.5 here — and swap the `MINISIGN_SECRET_KEY` repo
secret *after* that release is published.
The old key keeps signing until the fleet has moved (there is no key-continuity counter; the pin
is absolute per binary). On suspected **compromise**: rotate the repo secret immediately, audit
recent releases' `.minisig` against the artifacts you built, delete anything unaccounted for, and
accept that binaries pinning the compromised key can only be reached by a release signed with it
— rotate *through* one last old-key release, then treat the old key as dead.

---

## 6. Extending the system

### 6.1 Adding a channel (e.g. `beta`)

`releases/latest/download/` is one namespace, so a second channel needs its own manifest asset
name (e.g. `manifest-beta.json`) or its own repo. Checklist: compile the channel builds with
`-DDAEMON_APP_UPDATE_CHANNEL=beta` and the beta feed URL; generate with
`release-manifest.sh <dir> <version> beta --out manifest-beta.json`; the trusted comment then
pins `daemon beta <version>`, so a beta manifest can never be replayed at the stable fleet (and
vice versa). Prereleases-on-stable (§3.2) cover the "RC" case without any of this.

### 6.2 Adding an artifact kind

Touch, in one change: `classify()` + docs header in `release-manifest.sh` (kind, os, capability
ceiling); the package job's compiled dial defines (`DAEMON_APP_UPDATE_CAPABILITY/_FEED_URL/
_PUBKEY`); the client's `kind` vocabulary (`parseManifest`/`selectArtifact` and, for a new
self-apply strategy, a `self_apply_*` backend + helper mode); the dial tables in
`daemon-app/packaging/UPDATES.md` §"Current per-artifact dials" and §1 here.

---

## 7. Invariants (never break these)

1. **Never publish an unsigned or test-key-signed manifest.** Clients reject it (good), but a
   correctly-signed hostile manifest is the threat model's root — the secret stays in the CI
   secret store, never on a dev box (E2Es generate throwaway keys).
2. **Feed version must be strictly increasing** across published stable releases; never reuse or
   lower a version (clients would go silent, not downgrade).
3. **`daemon-app/VERSION` == `./VERSION` at every release tag** (§2 invariant 1).
4. **Never raise a capability via the feed** — the feed dial is a ceiling-lowering device only;
   raising capability requires shipping binaries with a higher compiled dial.
5. **Manifest and artifacts live on the same release**, `file` fields stay bare names, and
   CPack-named Linux artifacts are never renamed at staging (sidecars reference exact names;
   renames must preserve the arch token or `release-manifest.sh` records `arch: unknown`,
   which clients never select).
6. **Asset replacement on a published release is only for §3.4 (add rows) and §5.1 (lower
   dials)** — never to swap artifact bytes under an existing name; changed bits ship as a new
   version.
7. **Real-machine validation before tagging** anything that touches the Windows or macOS
   apply paths (no CI coverage there yet); the AppImage E2E gate runs everywhere.
