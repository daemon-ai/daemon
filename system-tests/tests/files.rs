// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Jarrad Hope

//! Phase 4 filesystem-seam scenario: the daemon-backed `DaemonFsService` drives the GUI's
//! explorer/editor over the wire. A fresh GUI attaches to a pre-started daemon (behind a recording
//! proxy) and runs the headless fs probe (`DAEMON_APP_FS_PROBE`): listRoots -> open(root) -> write a
//! probe file -> read it back. We assert (via the proxy) the `FsRoots`/`FsList`/`FsWrite`/`FsRead`
//! frames crossed the socket and (via stdout) the round-trip succeeded against the real
//! `WorkspaceFs` - proving the fs seam is daemon-backed end to end, not local-disk.
//!
//! Skips when `CLIENT_GUI_BIN` / `DAEMON_BIN` are unset (e.g. CI didn't build the client).

use std::path::PathBuf;

use daemon_api::ApiRequest;
use daemon_system_tests::{parse_fs_summary, run_gui_fs, Daemon, RecordingProxy};

fn gui_bin() -> Option<PathBuf> {
    std::env::var_os("CLIENT_GUI_BIN").map(PathBuf::from)
}

fn daemon_bin() -> Option<PathBuf> {
    std::env::var_os("DAEMON_BIN").map(PathBuf::from)
}

#[test]
fn gui_fs_explorer_wires_through_to_workspace() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping gui_fs_explorer_wires_through: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping gui_fs_explorer_wires_through: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_fs(&gui, &proxy.socket, 30000).expect("gui runs");
    let summary = parse_fs_summary(&run.stdout);
    assert!(
        !summary.is_empty(),
        "no DAEMON_APP_FS summary line.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );

    // The workspace root resolved, a write succeeded, and the read returned exactly the bytes
    // written - the full content round-trip over the wire (the byte-array=bstr fix in action).
    assert_eq!(
        summary.get("write").map(String::as_str),
        Some("ok"),
        "fs write did not succeed; summary: {summary:?}\ndaemon log:\n{}",
        daemon.log_contents()
    );
    assert_eq!(
        summary.get("read").map(String::as_str),
        Some("ok"),
        "fs read did not match the written bytes; summary: {summary:?}\ndaemon log:\n{}",
        daemon.log_contents()
    );

    // And the typed frames really crossed the socket (proxy trace).
    let frames = proxy.requests();
    let has = |pred: fn(&ApiRequest) -> bool| frames.iter().any(pred);
    assert!(has(|r| matches!(r, ApiRequest::FsRoots)), "no FsRoots: {frames:?}");
    assert!(has(|r| matches!(r, ApiRequest::FsList { .. })), "no FsList: {frames:?}");
    assert!(has(|r| matches!(r, ApiRequest::FsWrite { .. })), "no FsWrite: {frames:?}");
    assert!(has(|r| matches!(r, ApiRequest::FsRead { .. })), "no FsRead: {frames:?}");
}
