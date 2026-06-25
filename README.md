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
- `tools/` - cross-repo automation (codec vendoring/drift checks).

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
ciborium types) and owns C codec generation and its proof. `daemon-app` vendors
the checked-in generated C and compiles it (no Python in its build). The
superproject keeps the vendored copy in sync via `tools/` and fails CI on drift.
