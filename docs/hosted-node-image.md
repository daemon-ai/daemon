# Hosted-node OCI image

**Scope:** the deployment-image shape for a self-contained "hosted node" — the `daemon-node`
Rust backend serving its own Qt WebAssembly GUI on one origin — packaged as the input a
microVM-based hosting provider ingests. Built by this repo's flake as
`packages.hosted-node-oci` (`just build-image`).

**Sources:** the hosted-nodes draft spec (`daemon-api/docs/hosted-nodes.md`, 2026-07-03; not
yet in-tree — section references below cite it), daemon-node's single-origin web front
(`web.addr` / `web.root` + the `/ws` CBOR mux), daemon-app's `packages.wasm` browser bundle,
and the superproject `bundleWithDaemon` pattern. Originally prototyped standalone against the
pre-merge feature branches; everything here reflects the merged children and the superproject
wiring.

---

## 1. "Firefly"? — Firecracker, and what the providers actually ingest

There is no "Firefly" image format. The thing in play is **Firecracker**, AWS's microVM
monitor (KVM-based, used by Lambda/Fargate) — and it is what **Fly.io Machines** run on.
Firecracker itself has *no image format*: it boots an uncompressed Linux kernel plus a raw
block-device rootfs (typically ext4) handed to it by whoever operates it. Nobody "ships a
Firecracker image" to a provider; you ship what the provider's control plane converts.

What the hosted-nodes spec actually says:

| Spec location | Fact |
|---|---|
| §0 decision table | Launch compute provider: **Fly Machines (Firecracker microVMs)** |
| §5 `node_versions.image_ref` | `TEXT NOT NULL -- OCI ref incl. digest` |
| §7.3 machine config | `"image": "<node_versions.image_ref>"` — the Fly Machines API takes an **OCI/Docker registry reference** and converts it to a Firecracker rootfs server-side |
| §8.1 | "The hosted-node **OCI image** (built in the `daemon` repo, published to a registry the hosting worker can reference)" — dependency **D4**, blocking |
| §8.1.5 | "Image tags are immutable digests; `node_versions.image_ref` pins digests" |
| §6 / §19 | Other substrates are futures behind `ComputeProviderAdapter`: Cloudflare Containers (also OCI; deferred until persistent volumes), TEE-CVM (Phala-class, also OCI-shaped), "self-operated" (the only case where raw kernel+rootfs would ever be ours to build) |

**Conclusion: the spec is not ambiguous.** The deliverable is an **OCI image** — buildable
purely with `pkgs.dockerTools.buildLayeredImage`, no VM tooling involved. A raw Firecracker
kernel/rootfs pair (or a microvm.nix guest) is only relevant to a hypothetical self-operated
substrate, which the spec keeps as a far-future adapter. The flake therefore ships the OCI
image as *the* artifact and documents the microvm.nix seam in §7 below rather than building it.

### Lifecycle / boot expectations extracted from the spec (what the image must satisfy)

- **PID 1 = the daemon** (or a minimal SIGTERM-forwarding init); configured entirely by env
  (§8.1.1). Prompt, clean exit on SIGTERM (§8.3.4; conformance test 7).
- **Web front on `0.0.0.0:8080`** (§7.3 `internal_port`, §8.2 `DAEMON_WEB__ADDR`); the Qt
  WASM bundle at a fixed path, spec suggests `/opt/daemon/web` (§8.2 `DAEMON_WEB__ROOT`),
  **including precompressed `.br`/`.gz` siblings** (§8.1.2).
- **All durable state under `/data`** (§8.2 `DAEMON_DATA_DIR`), the provider volume
  mountpoint; `DAEMON_STORE=sqlite`. Machine stop/start/replace keeps the volume (§2.1.6).
- **No SSH, no shell listener; nothing listens except the web front** (§8.1.4).
- **Health = `GET /` returning the GUI entry page** (§7.3 check, §8.4); `/healthz` is
  future dependency D3.
- **Boot order** (§8.3): read env → root state under `/data` → first-boot seeding (SCRAM
  identity + Daemon Cloud credential, dependencies D1/D2, still open in daemon-node) →
  serve `:8080`.
- **No local inference** on hosted plans (§3.1); inference goes through the Daemon Cloud
  gateway (attach key, `daemon_api` provider) or customer BYOK — both are in-process HTTP
  client paths in the daemon binary.

### Networking / TLS assumptions

- TLS (`https://` + `wss://`) **terminates at the provider edge** (fly-proxy); the machine
  sees plain HTTP/WS on 8080 (§4.1, §7.3 handlers `["tls","http"]`).
- The web front's same-origin WS gate derives the self-origin as `http://<Host>` — behind
  edge TLS the browser's `Origin` is `https://…`, so **the public origin(s) must be listed
  in `DAEMON_API__WS_ALLOWED_ORIGINS`** (§8.2): `https://<slug>.nodes.daemon.ai` and
  `https://dn-<ulid>.fly.dev`. Verified working syntax:
  `DAEMON_API__WS_ALLOWED_ORIGINS=["https://a","https://b"]` (JSON-style array through
  figment's env layer — spike S2, answered).
- Hostname: CNAME + Fly-managed cert on shared IPv4 (SNI) + dedicated IPv6; cert issuance
  is async and non-blocking-degraded (§7.4).

---

## 2. What the flake builds

The superproject flake composes the two submodule flakes (`path:./daemon-node`,
`path:./daemon-app` — the gitlinks pin the exact child commits a bundle ships), so every
build is submodule-aware: `nix build '.?submodules=1#hosted-node-oci'`, or `just build-image`
(out-link `result-image`).

| Output | What it is |
|---|---|
| `packages.bundled-web` | `buildEnv` of the daemon + the wasm web root + the `hosted-node` launcher; host-runnable, and the microvm.nix seam (§7) |
| `packages.hosted-node-oci` | `dockerTools.buildLayeredImage` (docker-archive tarball): entrypoint `/bin/hosted-node`, `EXPOSE 8080`, `VOLUME /data`, `/opt/daemon/web` symlinked to the bundle |
| `apps.bundled-web` | host-local smoke run of the exact launcher (override `DAEMON_WEB__ADDR` / `DAEMON_DATA_DIR`) |

The image tag is the bundle version (`X.Y.Z+<n>.g<hash>` with `+` mapped to `_` — OCI tags
forbid `+`); the raw version rides in the `org.opencontainers.image.version` label. Digests,
not tags, are what the control plane pins.

The launcher mirrors `bundleWithDaemon`'s `--set-default` discipline — every value is an
env-overridable default (`${VAR:-default}`), then `exec`s the daemon (PID 1, direct signal
delivery):

```
DAEMON_WEB__ADDR=0.0.0.0:8080        # spec §7.3 / §8.2
DAEMON_WEB__ROOT=<store path of the wasm web root>
DAEMON_DATA_DIR=/data                # provider volume
DAEMON_STORE=sqlite
DAEMON_SOCKET_PATH=$DAEMON_DATA_DIR/daemon-api.sock   # not $TMPDIR: container /tmp is ephemeral-at-best
HOME=$DAEMON_DATA_DIR/home           # anything home-derived lands on the volume
SSL_CERT_FILE=<nixpkgs cacert>       # outbound TLS for the genai client (attach/BYOK)
```

Admin seeding stays daemon-node's contract: `DAEMON_ADMIN_USERNAME` +
`DAEMON_ADMIN_PASSWORD[_FILE]` env, else generated-and-printed-once to stderr + a `0600`
file under the data dir (which on a hosted node lands on the volume — see open question Q5).

Build-level details worth knowing:

1. **Precompressed siblings come from daemon-app.** The wasm bundle ships `.br`/`.gz`
   next to every artifact (brotli `-q 11` in its postInstall); the web front scans them at
   boot and negotiates `Accept-Encoding`. The 28.5 MB `.wasm` transfers as 8.6 MB brotli.
   (The pre-merge prototype had to generate these at image-build time; no longer.)
2. **`unsafeDiscardReferences` on the web root.** `daemon-app.wasm` embeds its qtbase-wasm
   store path as a dead string (compiled-in Qt prefix), which would otherwise drag the
   ~4.2 GiB Qt-for-WASM *build* closure into the image closure — measured on the prototype:
   the image tarball is **1.7 GB (97 layers) without the discard, ~0.1 GB (16 layers) with
   it**. The bytes are served verbatim to browsers; the reference is provably unused at
   runtime — the flake repacks the bundle into `daemon-web-root` with the reference
   discarded, keeping the image at daemon + bundle + glibc.
3. **No `StopSignal` override.** The pre-merge prototype declared `StopSignal=SIGINT`
   because the daemon's graceful shutdown was tokio's `ctrl_c()` only. daemon-node now traps
   SIGTERM next to SIGINT (registered before the node assembles, so an early stop queues
   instead of killing), so the runtime-default SIGTERM stops the container gracefully —
   verified sub-second under podman.
4. **`HOME` on the volume.** First boot of the pre-merge daemon panicked in `hf-hub`'s
   cache-dir probe without a `HOME`; daemon-node now boots HOME-less (lazy/fallible probe +
   fallback hub cache). The launcher still defaults `HOME=$DAEMON_DATA_DIR/home` so anything
   home-derived is durable on the volume rather than image-ephemeral.

### Sizes (measured 2026-07-03, post-merge)

Smaller than the pre-merge prototype (104 MB): the merged wasm build is size-optimized and
trims the unused Quick Controls styles.

| Artifact | Size |
|---|---|
| OCI tarball `hosted-node-oci` (docker-archive, gzipped) | **96 MB** — 16 layers |
| `bundled-web` closure (= unpacked image content) | 221 MiB |
| daemon binary | 126 MB (`bin/daemon`) |
| wasm web root (identity + `.br`/`.gz` siblings) | 50 MiB |
| `daemon-app.wasm` transfer size | 28.5 MB identity → 8.6 MB brotli |
| daemon-infer-llama (EXCLUDED) | would add ~53 MiB closure |

---

## 3. daemon-infer: excluded, deliberately

**Decision: the v1 hosted-node image ships WITHOUT `daemon-infer` (and without
`daemon-metta`).**

- The spec *forbids* local inference on hosted plans: §3.1 "**No GPU, ever** … Local
  inference (`llama.cpp` / `mistral.rs`) is disabled on hosted nodes; inference routes
  through Daemon Cloud (attach) or customer BYOK. This is a hard product rule." §8.1.3
  merely *permits* the workers to be present-but-disabled.
- A chat turn against a cloud profile (`daemon_api` attach or `genai` BYOK) is served by
  the **in-process genai HTTP client** in the daemon binary (rustls; hence the launcher's
  `SSL_CERT_FILE`). The `daemon-infer` worker is only spawned for the `llama`/`mistralrs`
  provider kinds and for `DAEMON_EMBED__PROVIDER=local` — none of which a hosted node
  configures. Nothing at boot requires the worker to exist.
- Cost of inclusion: ~53 MiB closure (llama-featured worker) for a permanently-dead code
  path, plus its supply-chain surface inside the image.
- Re-inclusion is one line if the posture changes (e.g. a future CPU-only embeddings tier):
  add `daemonInferLlama` to `bundledWeb`'s `paths` and a `DAEMON_INFER__WORKER_BIN` default
  in the launcher — exactly how `bundleWithDaemon` wires it for the desktop bundle. (The
  daemon's own next-to-exe worker discovery cannot work in Nix packaging: the daemon's store
  path contains no worker.) Keep it a *separate* package (`hosted-node-oci-infer`) rather
  than a flag, so image digests stay 1:1 with contents.

Consequence to document for users: on a hosted node the local-model surface of the GUI
(model download/quant picker) has no backend; profile creation should steer to Daemon
Cloud / BYOK. That is a product/UX concern (D6), not an image concern.

---

## 4. Verification evidence

All originally verified on the pre-merge prototype (2026-07-03) and re-verified after the
superproject integration, everything under **rootless podman**. Two host caveats worth
knowing for CI: (a) a NixOS host may lack `/etc/containers/policy.json` and podman has no
per-invocation policy flag — fixed by pointing `HOME` at a scratch dir containing a minimal
`.config/containers/policy.json` (`insecureAcceptAnything`), which also keeps podman's image
storage out of the real home; (b) the smoke runs `--network=host` bound to `127.0.0.1` for
the probe (rootless port-forward would also work).

```console
$ just build-image && podman load -i result-image
Loaded image: localhost/daemon-hosted-node:<tag>
$ podman run -d --name hosted-node-smoke --network=host \
    -e DAEMON_WEB__ADDR=127.0.0.1:8093 \
    -e DAEMON_ADMIN_USERNAME=operator -e DAEMON_ADMIN_PASSWORD=… \
    -v /tmp/hosted-node-data:/data localhost/daemon-hosted-node:<tag>

# 1. the single-origin listener line (startup log):
INFO daemon: serving web app bundle + daemon-api WebSocket at /ws
     (single origin, authentication required) addr=127.0.0.1:8093
     root=/nix/store/…-daemon-web-root/share/daemon-app/wasm

# 2. GUI entry + wasm Content-Type + brotli negotiation:
$ curl -sI http://127.0.0.1:8093/                    # → 200, text/html; charset=utf-8
$ curl -sI http://127.0.0.1:8093/daemon-app.wasm     # → 200, application/wasm, ~43 MB
$ curl -sI -H 'Accept-Encoding: br' …/daemon-app.wasm
# → 200, application/wasm, content-encoding: br, ~12 MB, vary: accept-encoding

# 3. WS upgrade gate on /ws (raw HTTP/1.1 probe, Sec-WebSocket-Protocol: daemon-mux):
Origin: http://127.0.0.1:8093              → 101 Switching Protocols, sec-websocket-protocol: daemon-mux
Origin: https://evil.example.com           → 403 Forbidden
# with -e DAEMON_API__WS_ALLOWED_ORIGINS='["https://node1.nodes.daemon.ai","https://dn-x.fly.dev"]':
Origin: https://node1.nodes.daemon.ai      → 101 Switching Protocols
Origin: https://dn-x.fly.dev               → 101 Switching Protocols
Origin: https://evil.example.com           → 403 Forbidden

# 4. persistence: /data (the bind mount) after first boot:
auth.sqlite  blobs/  daemon-api.sock  daemon-store.sqlite  default/  home/  profiles/  revisions/
# a second run against the same volume reuses it (no re-seed).

# 5. graceful stop on the runtime-default SIGTERM (no StopSignal override):
$ time podman stop hosted-node-smoke      # sub-second
```

---

## 5. Publishing (D4's second half — as-built runbook)

`just push-image` pushes the docker-archive (`result-image`) to a registry with **skopeo**
and records the immutable **digest** that `node_versions.image_ref` pins. Tags are labels;
the digest is the contract (§8.1.5). skopeo and jq are pinned in the superproject devShell
(`nix develop`), so the pipeline uses the same versions everywhere.

### Registry

- **Primary: GitHub Container Registry — `ghcr.io/<org>/daemon-hosted-node`.** The repo is on
  GitHub and CI is GitHub Actions, so in CI the built-in `GITHUB_TOKEN` (with `packages: write`)
  authenticates a push — no separate secret to provision. GHCR gives OCI manifest digests and
  shares fat layers (glibc, WASM bundle) across daemon-version pushes, so fleet rollout pulls
  move only the daemon-binary layer (§16).
- **Fallback: `registry.fly.io/<app>`.** The compute provider is Fly Machines, which can pull
  from its own registry with no cross-registry credential (`fly auth docker` → an authfile). Use
  this only if GHCR pull-auth from Fly ever proves awkward; it couples the image to a Fly app
  namespace.

Repo = `${REGISTRY}/${IMAGE_ORG}/${IMAGE_NAME}`. All three are overridable
(`REGISTRY=ghcr.io`, `IMAGE_NAME=daemon-hosted-node` by default); **`IMAGE_ORG` has no default
and must be set explicitly** — the recipe fails fast otherwise (the expected production value is
`daemon-ai`, once that GitHub org is confirmed). The tag is derived from the image's
`org.opencontainers.image.version` label with `+`→`_` — the exact scheme the flake stamps the
OCI tag with — so the pushed tag always matches what nix chose.

### Credentials (env only, never stored)

Supply exactly one of:

- `REGISTRY_USER` + `REGISTRY_PASSWORD` (e.g. a GHCR PAT with `write:packages`) → skopeo
  `--dest-creds` / `--creds`; or
- `REGISTRY_AUTH_FILE` pointing at a file from a prior out-of-band `skopeo login` / CI token →
  skopeo `--authfile`.

Credentials live only in the process environment (or an authfile outside the repo). Nothing is
written into the tree; `.env` and `/dist/` are git-ignored.

### Operator flow

```console
$ nix develop                                    # skopeo + jq + just on PATH
$ just build-image                               # -> result-image (or reuse an existing one)
$ export REGISTRY_USER=<you> REGISTRY_PASSWORD=<ghcr-pat>
$ just push-image IMAGE_ORG=daemon-ai            # push + read digest back
push-image: copying result-image -> docker://ghcr.io/daemon-ai/daemon-hosted-node:0.0.1_g<rev>
push-image: pushed  ghcr.io/daemon-ai/daemon-hosted-node:0.0.1_g<rev>
push-image: image_ref = ghcr.io/daemon-ai/daemon-hosted-node@sha256:<digest>
push-image: recorded -> dist/hosted-node-digest.txt   (paste into node_versions API as image_ref)
```

Then, on the daemon-api (hosting admin) side, **paste that `…@sha256:…` ref into the
`node_versions` API as `image_ref`** — create a row with `channel` `stable` (or `canary`, below),
`wire_version` admin-entered (§16), and roll it out. `node_versions` pins the digest, never the
tag, so a moved/overwritten tag can never repoint a fleet.

**Canary:** `just push-image CHANNEL=canary IMAGE_ORG=daemon-ai` pushes a `…-canary` tag to the
*same* repo — the digest is identical in kind and channel is just a `node_versions` column, so
promotion `canary`→`stable` is a DB action with no re-push.

### Dry-run verification (no registry, no credentials)

`just verify-push` spins up a throwaway `registry:2` on `127.0.0.1:5000` under rootless podman,
runs the exact `push-image` path against it insecurely (`REGISTRY_INSECURE=1`), and prints the
recorded digest — proving the push→digest pipeline offline. The dry-run digest is a *pipeline*
proof only: the real `node_versions` value comes from the production GHCR push, since manifest
digests are registry-specific. Where podman is unavailable, the same archive copies to a local
OCI layout with no daemon or network —
`skopeo copy docker-archive:result-image oci:dist/oci-layout:test` then
`skopeo inspect oci:dist/oci-layout:test | jq -r .Digest` (this is the path used to verify the
pipeline at build time).

**Trust policy (NixOS caveat).** skopeo requires a containers trust policy, and nixpkgs ships
none — a NixOS host has no `/etc/containers/policy.json` (the same gap §4 notes for podman). The
recipe handles this automatically: it uses `$SKOPEO_POLICY` if set, else an existing
system/user policy, else it synthesizes the standard accept-all default in a temp file. Set
`SKOPEO_POLICY=/path/to/policy.json` to enforce a stricter policy.

### Notes

- **Architecture:** the WASM build only works on `x86_64-linux`/`aarch64-linux` (emscripten
  pin) and `dockerTools` builds per-system; v1 publishes **x86_64-only** (Fly is x86_64-first,
  Q9). A manifest list is a later `push-image` extension (`skopeo copy --all` / `--multi-arch`),
  not built here.
- **CI automation is deferred** until registry credentials exist; the manual runbook above is the
  accepted v1 floor.

---

## 6. TLS / origin guidance for providers (operator-facing)

- The image serves **plain HTTP** on 8080. The provider edge owns `https://`/`wss://`
  (Fly: handlers `["tls","http"]` on 443, force-https on 80).
- Same-origin browser use *without* a proxy (dev, LAN appliance) needs **zero origin
  config** — the web front accepts `Origin == http://<Host>` automatically.
- Behind any TLS terminator, provisioning must inject the public origin(s):
  `DAEMON_API__WS_ALLOWED_ORIGINS=["https://<slug>.nodes.daemon.ai","https://dn-<ulid>.fly.dev"]`
  (JSON-style array through figment's env layer — verified). If the env layer ever proves
  awkward, inject a one-line TOML via `DAEMON_CONFIG` instead
  (`api.ws_allowed_origins = [...]`) — the config-file fallback the spec reserves.
- Everything on `/ws` is SCRAM-authenticated regardless of origin; static files are
  public by design (the GUI must load before login). Don't put secrets in the bundle.

## 7. The self-hosted / microvm.nix seam (not built, documented)

If a self-operated Firecracker/cloud-hypervisor substrate ever materializes (§19's
"self-operated future"), the same `bundled-web` package drops into a microvm.nix guest as
a systemd unit — no image conversion involved, the store closure *is* the rootfs:

```nix
# flake input: microvm.url = "github:astro/microvm.nix";
nixosConfigurations.hosted-node-vm = nixpkgs.lib.nixosSystem {
  inherit system;
  modules = [ microvm.nixosModules.microvm {
    microvm = {
      hypervisor = "firecracker";        # or cloud-hypervisor / qemu
      vcpu = 2; mem = 4096;              # node-standard shape (§3.1)
      volumes = [ { mountPoint = "/data"; image = "data.img"; size = 10 * 1024; } ];
      shares = [ { proto = "virtiofs"; tag = "ro-store"; source = "/nix/store"; mountPoint = "/nix/.ro-store"; } ];
      interfaces = [ { type = "tap"; id = "vm-node"; mac = "…"; } ];
    };
    systemd.services.hosted-node = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { ExecStart = "${bundled-web}/bin/hosted-node"; Restart = "always"; };
    };
    networking.firewall.allowedTCPPorts = [ 8080 ];
  } ];
};
```

This stays a sketch on purpose: no provider in the spec ingests it, and keeping it out of
the build matrix avoids paying microvm.nix's input closure on every superproject lock.

## 8. Data-dir / persistence expectations (from the spec, restated for the image)

- One volume, mounted `/data`; **everything durable roots there**: `daemon-store.sqlite`,
  `auth.sqlite`, `blobs/`, `workspaces/`, per-profile subsystem DBs (§2.1.1). The image
  declares `VOLUME /data` and the launcher `mkdir -p`s it (first boot on an empty volume;
  the daemon also auto-creates its data dir `0700` since the hosted-boot hardening).
- Suspend/stop keeps the volume; restore = *new* volume + machine from a snapshot (§7.5) —
  the image is stateless by construction, so this is free as long as nothing durable ever
  lands outside `/data` (hence the socket-path default override in the launcher).
- Restart-safety is a daemon design invariant (recover-from-store, crash-after-boundary
  conformance gates) — the image adds nothing and must subtract nothing: no init system
  that buffers SIGTERM, no state in `/tmp` beyond genuinely ephemeral files.

## 9. Open questions for the daemon-api hosted-nodes work (enumerate-only)

0. ~~**SIGTERM handling in daemon-node.**~~ **Resolved** by the hosted-boot hardening:
   the host loop selects over `ctrl_c()` *and* `SignalKind::terminate()` (registered at
   `run_as_host` entry, so a stop during assembly queues instead of killing). The image
   needs no `StopSignal` override; `podman stop` is sub-second.
1. **D1/D2 bootstrap env names.** `DAEMON_BOOTSTRAP__USER/SECRET/DAEMON_API_KEY` are
   provisional in the spec; the daemon currently ships `DAEMON_ADMIN_USERNAME/PASSWORD`
   (+`_FILE`) for the first-admin seed and nothing for credential-store seeding. Aligning
   names (or documenting both) is a daemon-node decision the spec defers — the image
   passes env through either way.
2. **`ws_allowed_origins` env-list syntax (spike S2) — answered.** Verified working:
   `DAEMON_API__WS_ALLOWED_ORIGINS=["https://node1.nodes.daemon.ai","https://dn-x.fly.dev"]`
   (JSON-style array through figment's env layer; probes returned 101 for listed origins,
   403 otherwise). The Fly adapter can inject plain env; no config-file fallback needed.
3. **`/healthz` (D3).** Until it lands, providers health-check `GET /` (returns the GUI
   HTML — verified 200). Fine for liveness; useless for store/journal readiness.
   When D3 lands, the image needs no change (same listener).
4. **Journal-seed handling.** `DAEMON_JOURNAL_SEED` is 64-hex-char via env — fine as a
   provider secret; nothing image-side. But note the daemon *regenerates per boot* when
   unset: provisioning MUST set it or verifying keys rotate on every restart (§2.1.7).
5. **Generated-admin fallback on hosted nodes.** If provisioning ever boots a node without
   `DAEMON_ADMIN_*`, the daemon prints a generated password to stderr (provider log
   pipeline!) and writes `first-admin-credentials.txt` onto the volume. Provisioning
   should always seed explicitly; the spec's D1 flow does — worth a hard requirement.
6. ~~**Headless-container boot assumptions.**~~ **Resolved** by the hosted-boot hardening:
   the daemon boots with no `HOME` and no `/etc/passwd` (the hub-cache probe is no longer
   fatal, with a data-dir fallback). The launcher still roots `HOME` on the volume for
   durability (§2 point 4).
7. ~~**Image publishing pipeline (D4's CI half).**~~ **Wired** as `just push-image` (skopeo
   push → digest recorded to `dist/hosted-node-digest.txt`; registry GHCR, canary = `-canary`
   tag suffix — §5 above). Remaining: an operator pastes the digest into the `node_versions`
   API, and CI automation is deferred until registry credentials exist.
8. **Wire-version stamping.** `node_versions.wire_version` is informational; if the
   hosting worker wants it machine-readable, an OCI label
   (`ai.daemon.wire-version=<N>`) on the image is a one-liner in the `config.Labels`
   attrset — needs the daemon to export the number at build time.
9. **aarch64 images.** Fly Machines are x86_64-first (arm64 exists in some regions);
   dockerTools builds per-system. Decide whether D4 publishes a manifest list or
   x86_64-only at launch.
