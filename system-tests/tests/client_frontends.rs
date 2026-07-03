// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Jarrad Hope

//! Frontend smoke scenarios: launch the real GUI/TUI client against the recording proxy in daemon
//! mode and offscreen, proving the daemon-mode service graph + vendored codec initialize end-to-end
//! without crashing. They skip when the client binary env var is unset (e.g. CI didn't build it).
//!
//! The daemon-mode client auto-connects and sends a Health probe; because the offscreen harnesses
//! are not (yet) designed to block until that async round-trip completes, the Health observation is
//! logged opportunistically rather than asserted. Tightening that into a hard assertion is a small
//! harness/offscreen-mode enhancement tracked in the plan.

use std::path::PathBuf;
use std::time::Duration;

use daemon_api::ApiRequest;
use daemon_system_tests::{
    run_gui_offscreen, run_gui_wait_ready, run_tui_offscreen, run_tui_wait_ready, Daemon,
    RecordingProxy,
};

fn have_daemon() -> bool {
    std::env::var_os("DAEMON_BIN").is_some() && std::env::var_os("DAEMON_CLI_BIN").is_some()
}

#[test]
fn gui_offscreen_initializes_in_daemon_mode() {
    if !have_daemon() {
        eprintln!("skipping gui_offscreen_initializes_in_daemon_mode: daemon binaries unset");
        return;
    }
    let gui = match std::env::var_os("CLIENT_GUI_BIN") {
        Some(p) => PathBuf::from(p),
        None => {
            eprintln!("skipping gui_offscreen_initializes_in_daemon_mode: CLIENT_GUI_BIN unset");
            return;
        }
    };

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_offscreen(&gui, &proxy.socket, None).expect("gui runs");
    assert!(
        run.success,
        "GUI offscreen render in daemon mode failed.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );

    // The real GUI binary, headless in daemon mode pointed at the proxy via DAEMON_APP_SOCKET,
    // auto-connects and sends a Health probe - a genuine GUI -> daemon round-trip over the Unix
    // socket, decoded here with the daemon's own daemon-api types.
    let health = proxy
        .requests()
        .iter()
        .any(|r| matches!(r, ApiRequest::Health));
    assert!(
        health,
        "expected the GUI to send a Health probe over the socket; frames: {:?}\ndaemon log:\n{}",
        proxy.frames(),
        daemon.log_contents()
    );
}

#[test]
fn tui_offscreen_initializes_in_daemon_mode() {
    if !have_daemon() {
        eprintln!("skipping tui_offscreen_initializes_in_daemon_mode: daemon binaries unset");
        return;
    }
    let tui = match std::env::var_os("CLIENT_TUI_BIN") {
        Some(p) => PathBuf::from(p),
        None => {
            eprintln!("skipping tui_offscreen_initializes_in_daemon_mode: CLIENT_TUI_BIN unset");
            return;
        }
    };

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_tui_offscreen(&tui, &proxy.socket, (40, 120), None, None).expect("tui runs");
    assert!(
        run.success,
        "TUI offscreen frame dump in daemon mode failed.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );
    assert!(
        !run.stdout.is_empty(),
        "expected a rendered TUI frame on stdout"
    );

    let health = proxy
        .requests()
        .iter()
        .any(|r| matches!(r, ApiRequest::Health));
    eprintln!("tui daemon-mode Health probe observed over the socket: {health}");
}

/// Hard-assert connectivity: with DAEMON_APP_WAIT_READY the GUI blocks until its Health round-trip
/// resolves, so we can assert both the readiness sentinel and that the daemon observed Health plus
/// the auto SessionsQuery that fires once the connection is ready.
#[test]
fn gui_daemon_mode_reaches_ready_and_queries_sessions() {
    if !have_daemon() {
        eprintln!(
            "skipping gui_daemon_mode_reaches_ready_and_queries_sessions: daemon binaries unset"
        );
        return;
    }
    let gui = match std::env::var_os("CLIENT_GUI_BIN") {
        Some(p) => PathBuf::from(p),
        None => {
            eprintln!(
                "skipping gui_daemon_mode_reaches_ready_and_queries_sessions: CLIENT_GUI_BIN unset"
            );
            return;
        }
    };

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_wait_ready(&gui, &proxy.socket, 5000).expect("gui runs");
    assert!(
        run.success && run.stdout.contains("DAEMON_APP_READY ok"),
        "GUI did not reach daemon-ready.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );

    proxy
        .wait_for_request(|r| matches!(r, ApiRequest::Health), Duration::from_secs(2))
        .expect("GUI sent a Health probe");
    proxy
        .wait_for_request(
            |r| matches!(r, ApiRequest::SessionsQuery { .. }),
            Duration::from_secs(2),
        )
        .expect("GUI sent a SessionsQuery once ready");
}

/// Same hard-assert for the TUI: the readiness block makes the Health probe assertable (previously
/// only logged), and the auto SessionsQuery on ready is observed at the socket.
#[test]
fn tui_daemon_mode_reaches_ready_and_queries_sessions() {
    if !have_daemon() {
        eprintln!(
            "skipping tui_daemon_mode_reaches_ready_and_queries_sessions: daemon binaries unset"
        );
        return;
    }
    let tui = match std::env::var_os("CLIENT_TUI_BIN") {
        Some(p) => PathBuf::from(p),
        None => {
            eprintln!(
                "skipping tui_daemon_mode_reaches_ready_and_queries_sessions: CLIENT_TUI_BIN unset"
            );
            return;
        }
    };

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_tui_wait_ready(&tui, &proxy.socket, (40, 120), 5000).expect("tui runs");
    assert!(
        run.stdout.contains("DAEMON_APP_READY ok"),
        "TUI did not reach daemon-ready.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );

    proxy
        .wait_for_request(|r| matches!(r, ApiRequest::Health), Duration::from_secs(2))
        .expect("TUI sent a Health probe");
    proxy
        .wait_for_request(
            |r| matches!(r, ApiRequest::SessionsQuery { .. }),
            Duration::from_secs(2),
        )
        .expect("TUI sent a SessionsQuery once ready");
}
