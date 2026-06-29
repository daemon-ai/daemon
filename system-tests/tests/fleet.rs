// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Jarrad Hope

//! Phase 5b fleet scenario (story 02: PRO-9 view + PRO-10 control): a fresh GUI attaches to a
//! pre-started daemon (behind a recording proxy) and runs the headless fleet probe
//! (`DAEMON_APP_FLEET_PROBE`): refresh the subagent `Tree`, then `Pause` a unit. We assert the
//! `Tree` + `Pause` frames crossed the socket against the real NodeApi - proving the fleet seam is
//! daemon-backed, not the mock. (A fresh daemon has no delegated subagents, so the tree is empty and
//! the Pause is rejected; the wire-crossing is what PRO-9/10 require.)
//!
//! Skips when `CLIENT_GUI_BIN` / `DAEMON_BIN` are unset.

use std::path::PathBuf;

use daemon_api::ApiRequest;
use daemon_system_tests::{run_gui_fleet, Daemon, RecordingProxy};

fn gui_bin() -> Option<PathBuf> {
    std::env::var_os("CLIENT_GUI_BIN").map(PathBuf::from)
}

fn daemon_bin() -> Option<PathBuf> {
    std::env::var_os("DAEMON_BIN").map(PathBuf::from)
}

#[test]
fn gui_fleet_tree_and_control_wire_through() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping gui_fleet_tree_and_control: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping gui_fleet_tree_and_control: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_fleet(&gui, &proxy.socket, 30000).expect("gui runs");
    assert!(
        run.stdout.contains("DAEMON_APP_FLEET units="),
        "no DAEMON_APP_FLEET units= line.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );

    // The Tree query + the Pause control op really crossed the socket (proxy trace).
    let frames = proxy.requests();
    let has = |pred: fn(&ApiRequest) -> bool| frames.iter().any(pred);
    assert!(has(|r| matches!(r, ApiRequest::Tree)), "no Tree: {frames:?}");
    assert!(has(|r| matches!(r, ApiRequest::Pause { .. })), "no Pause: {frames:?}");
}
