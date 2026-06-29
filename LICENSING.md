# Licensing

This repository is a superproject (an *aggregate*) that tracks two independent
submodules plus a thin integration layer. It does not have a single repo-wide
license; each component is licensed under its own terms, summarized below.

Copyright holder across all components: **Jarrad Hope**.

| Component | Path | License (SPDX) |
| --- | --- | --- |
| Rust backend | `daemon-node/` (submodule) | `MIT OR Apache-2.0` |
| Qt 6 client (GUI + TUI) | `daemon-app/` (submodule) | `MPL-2.0` |
| Superproject glue | `system-tests/`, `flake.nix`, `justfile`, `scripts/` | `MIT OR Apache-2.0` |

The glue license texts live at the repository root: [`LICENSE-MIT`](LICENSE-MIT)
and [`LICENSE-APACHE`](LICENSE-APACHE) (canonical copies are also in
[`LICENSES/`](LICENSES/) for [REUSE](https://reuse.software/) tooling).

## Why an aggregate, not a single license

`daemon-app` and `daemon-node` are separate processes that communicate over a
length-framed CBOR Unix socket (see the sync-protocol spec); neither statically
links the other. Their licenses therefore do not combine across that boundary.

`MPL-2.0` is file-level (weak) copyleft and is one-way compatible with the
permissive `MIT`/`Apache-2.0` code: permissive code may be combined into the MPL
client, but MPL-covered files cannot be relabeled as MIT/Apache. Because some
files are MPL-only, the tree as a whole cannot be offered as a single
"MIT OR Apache-2.0" dual license -- hence this per-component model.

The `daemon-app` MPL files are **not** marked "Incompatible With Secondary
Licenses" (MPL Exhibit B is intentionally omitted), so they may be combined with
GPL/LGPL components where required.

## Third-party components

Each submodule documents the third-party code it vendors or builds against:

- `daemon-app/THIRD-PARTY-NOTICES.md` -- GUI/TUI build-time dependencies
  (including the GPL-2.0 embedded terminal and LGPL-2.1 global-shortcut
  components) and the in-tree vendored zcbor (Apache-2.0) and Tui Widgets
  (BSL-1.0).
- `daemon-node/NOTICE` -- optional, feature-gated engine lanes (llama.cpp,
  hyperon; both MIT).

## Contributions

Contributions to `daemon-node` and the superproject glue are accepted under
`MIT OR Apache-2.0`; contributions to `daemon-app` are accepted under `MPL-2.0`.
Unless stated otherwise, a contribution is licensed under the same terms as the
component it is submitted to.
