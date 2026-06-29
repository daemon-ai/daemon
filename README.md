# daemon

Superproject that tracks the daemon stack as a set of git submodules and hosts
the cross-repo end-to-end integration tests.

## Layout

- `daemon-node/` (submodule) - the Rust daemon: a length-framed CBOR Unix-socket
  API, C FFI bindings, and the authoritative `daemon-api` contract (CDDL +
  ciborium types).
- `daemon-app/` (submodule) - the Qt 6 thin client: a QML/Qt Quick GUI
  (`daemon-app`) and a Tui Widgets TUI (`daemon-tui`), sharing one service graph
  and the vendored zcbor codec generated from the daemon contract.
- `system-tests/` - the Rust end-to-end harness that drives the real GUI/TUI
  binaries against a real daemon over an isolated Unix socket, asserting on a
  typed protocol trace (decoded with `daemon-api`'s own types).
- `flake.nix` - the cross-repo codec sync: a pure `packages.daemon-zcbor-codec`
  derivation, a `checks.codec-drift` gate, and an `apps.update-codec` helper.
- `justfile` - one entry point for builds, the codec contract, and the E2E suite
  (`just` to list recipes).

## Working with submodules

```sh
git clone --recurse-submodules git@github.com:daemon-ai/daemon.git
# or, after a plain clone:
git submodule update --init --recursive
```

Each submodule remains an independent repository with its own flake and test
gate; this superproject pins a compatible revision of each and adds the
integration layer on top.

## Contract ownership

`daemon-node` is authoritative for the wire contract (`daemon-api.cddl` +
ciborium types) and owns C codec generation and its proof (`xtask verify-codec`).
The client-generatable view is `daemon-api-client.cddl`; `daemon-app` vendors the
checked-in generated C (`daemon_api_client_*`) plus the zcbor runtime and
compiles them (no Python in its build).

The superproject keeps the vendored copy in sync the Nix-idiomatic way. The
submodule contents are gitlinks, so these need `?submodules=1`:

```sh
nix build '.?submodules=1#checks.<system>.codec-drift'  # gate: vendored vs generated
nix run   '.?submodules=1#update-codec'                 # regenerate into the working tree
nix run   '.?submodules=1'                              # read-only status + drift report
```

CI builds the pure derivation and fails on drift; nothing mutates the tree
except the explicit `update-codec`.

## Licensing

This is an aggregate of independently-licensed components (copyright (c) 2026
Jarrad Hope):

- `daemon-node/` (submodule) - `MIT OR Apache-2.0`
- `daemon-app/` (submodule) - `MPL-2.0`
- superproject glue (`system-tests/`, `flake.nix`, `justfile`, `scripts/`) -
  `MIT OR Apache-2.0` (see [`LICENSE-MIT`](LICENSE-MIT) /
  [`LICENSE-APACHE`](LICENSE-APACHE))

See [`LICENSING.md`](LICENSING.md) for the full breakdown and rationale, and
[`NOTICE`](NOTICE) for third-party attributions.
