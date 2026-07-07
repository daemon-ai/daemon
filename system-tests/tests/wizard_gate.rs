// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Jarrad Hope

//! A7 (CON-7/8/9) — the first-run wizard's finish is gated on a REAL readiness probe, not on local
//! QSettings. The client only persists `setupComplete` after its daemon-mode connect reaches a
//! healthy `Health` round-trip (`awaitConnectionReady` + `settleFirstRunGate`); a connect that
//! never reaches ready leaves the gate closed and `setupComplete` false.
//!
//! This journey proves that asymmetry as the honest finish-gate contract:
//!   - healthy node  → the gate OPENS: `DAEMON_APP_READY ok` and `setupComplete=true` persists, with
//!     a real `Health` probe observed crossing the socket at the recording proxy;
//!   - unreachable node → the gate STAYS CLOSED: `DAEMON_APP_READY timeout` (honest feedback, not a
//!     silent success) and `setupComplete` is NOT persisted, so a returning launch re-enters
//!     onboarding rather than dead-ending on a chat that can never send.
//!
//! Both use the fresh managed-attach harness (`setupComplete=false`, `DAEMON_BIN` removed so no
//! spawn masks the probe). Skips when `CLIENT_GUI_BIN` / `DAEMON_BIN` are unset.

use std::path::PathBuf;
use std::time::Duration;

use daemon_api::ApiRequest;
use daemon_system_tests::{run_gui_first_run_attaches, Daemon, RecordingProxy};

fn daemon_bin() -> Option<PathBuf> {
    std::env::var_os("DAEMON_BIN").map(PathBuf::from)
}

fn gui_bin() -> Option<PathBuf> {
    std::env::var_os("CLIENT_GUI_BIN").map(PathBuf::from)
}

/// A7 (healthy): a fresh client attaches to a running, CONFIGURED daemon (mock provider + model, so
/// the node's first-run gate is satisfiable), reaches ready via a real `Health` probe, and the
/// finish gate persists `setupComplete=true`.
#[test]
fn finish_gate_opens_on_a_healthy_node() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping finish_gate_opens_on_a_healthy_node: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping finish_gate_opens_on_a_healthy_node: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_first_run_attaches(&gui, &proxy.socket, 8000).expect("gui runs");
    assert!(
        run.success && run.stdout.contains("DAEMON_APP_READY ok"),
        "the finish gate did not open on a healthy node.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );
    // The gate fired a REAL readiness probe (not just a local QSettings flip).
    proxy
        .wait_for_request(|r| matches!(r, ApiRequest::Health), Duration::from_secs(2))
        .expect("the finish gate probed the node with a real Health round-trip");
    assert!(
        run.persisted_setup_complete(),
        "a healthy connect must persist setupComplete (the gate opened).\nconfig: {}",
        run.config_path().display()
    );
}

/// A7 (unreachable): the fresh client is pointed at a socket path with NO listener and cannot spawn
/// (`DAEMON_BIN` removed, none on PATH). The connect never reaches ready — `DAEMON_APP_READY timeout`
/// — and the finish gate STAYS CLOSED: `setupComplete` is never persisted, so setup honestly did not
/// complete. This is the "done means proven" contract: a QSettings-only gate would have (wrongly)
/// reported success here.
#[test]
fn finish_gate_stays_closed_on_an_unreachable_node() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping finish_gate_stays_closed_on_an_unreachable_node: CLIENT_GUI_BIN unset");
        return;
    };

    // A short-pathed socket target that no daemon is listening on (must fit sun_path).
    let tmp = tempfile::Builder::new()
        .prefix("dst-a7-")
        .tempdir_in("/tmp")
        .expect("temp dir");
    let dead_socket = tmp.path().join("nobody.sock");

    let run = run_gui_first_run_attaches(&gui, &dead_socket, 3000).expect("gui runs");
    assert!(
        run.stdout.contains("DAEMON_APP_READY timeout"),
        "an unreachable node must report timeout (honest feedback), not a silent ok.\nstdout:\n{}\nstderr:\n{}",
        run.stdout,
        run.stderr
    );
    assert!(
        !run.persisted_setup_complete(),
        "an unreachable connect must NOT persist setupComplete (the gate stayed closed).\nconfig: {}",
        run.config_path().display()
    );
}
