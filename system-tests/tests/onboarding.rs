//! First-run onboarding scenarios (user story 01, CON-1 / CON-1b): a fresh client
//! (`setupComplete=false`) drives the "Local" connect, reaches a healthy daemon, and persists setup.
//!
//! Two local strategies are covered:
//!   - managed-spawn: no daemon is pre-started; the client discovers + spawns the `daemon` binary
//!     (DAEMON_BIN), reaches a healthy `Health`, and persists setupComplete.
//!   - attach (probe-first): a daemon is already listening; the client reuses it rather than
//!     spawning a second instance, with Health observed at the recording proxy.
//!
//! They skip when the relevant binaries are unset (e.g. CI didn't build the client).

use std::path::PathBuf;
use std::time::Duration;

use daemon_api::ApiRequest;
use daemon_system_tests::{
    run_gui_first_run_attaches, run_gui_first_run_spawns_daemon, run_tui_first_run_spawns_daemon,
    Daemon, RecordingProxy,
};

fn daemon_bin() -> Option<PathBuf> {
    std::env::var_os("DAEMON_BIN").map(PathBuf::from)
}

fn gui_bin() -> Option<PathBuf> {
    std::env::var_os("CLIENT_GUI_BIN").map(PathBuf::from)
}

fn tui_bin() -> Option<PathBuf> {
    std::env::var_os("CLIENT_TUI_BIN").map(PathBuf::from)
}

/// CON-1b: fresh GUI, no daemon running -> the client spawns one, reaches ready, persists setup.
#[test]
fn gui_first_run_spawns_local_daemon_and_persists_setup() {
    let (Some(gui), Some(daemon)) = (gui_bin(), daemon_bin()) else {
        eprintln!("skipping gui_first_run_spawns_local_daemon: CLIENT_GUI_BIN / DAEMON_BIN unset");
        return;
    };

    let run = run_gui_first_run_spawns_daemon(&gui, &daemon, 15000).expect("gui runs");
    assert!(
        run.stdout.contains("DAEMON_APP_READY ok"),
        "GUI first-run did not spawn + reach a healthy local daemon.\nstdout:\n{}\nstderr:\n{}",
        run.stdout,
        run.stderr
    );
    assert!(
        run.persisted_setup_complete(),
        "GUI first-run did not persist setupComplete after a successful connect.\nconfig: {}",
        run.config_path().display()
    );
}

/// CON-1b: fresh TUI, no daemon running -> the client spawns one, reaches ready, persists setup.
#[test]
fn tui_first_run_spawns_local_daemon_and_persists_setup() {
    let (Some(tui), Some(daemon)) = (tui_bin(), daemon_bin()) else {
        eprintln!("skipping tui_first_run_spawns_local_daemon: CLIENT_TUI_BIN / DAEMON_BIN unset");
        return;
    };

    let run = run_tui_first_run_spawns_daemon(&tui, &daemon, (40, 120), 15000).expect("tui runs");
    assert!(
        run.stdout.contains("DAEMON_APP_READY ok"),
        "TUI first-run did not spawn + reach a healthy local daemon.\nstdout:\n{}\nstderr:\n{}",
        run.stdout,
        run.stderr
    );
    assert!(
        run.persisted_setup_complete(),
        "TUI first-run did not persist setupComplete after a successful connect.\nconfig: {}",
        run.config_path().display()
    );
}

/// CON-1b probe-first: a daemon is already running, so the fresh client must attach to it (Health
/// observed at the proxy) without spawning a second. DAEMON_BIN is removed from the child env, so an
/// erroneous spawn attempt would fail discovery and leave the client offline - a passing ready +
/// Health assertion therefore proves probe-first attached rather than spawned.
#[test]
fn gui_first_run_attaches_without_double_spawn() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping gui_first_run_attaches: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping gui_first_run_attaches: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_first_run_attaches(&gui, &proxy.socket, 5000).expect("gui runs");
    assert!(
        run.success && run.stdout.contains("DAEMON_APP_READY ok"),
        "GUI first-run did not attach to the running daemon.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );

    proxy
        .wait_for_request(|r| matches!(r, ApiRequest::Health), Duration::from_secs(2))
        .expect("GUI sent a Health probe over the existing daemon's socket");
    assert!(
        run.persisted_setup_complete(),
        "GUI first-run did not persist setupComplete after attaching.\nconfig: {}",
        run.config_path().display()
    );
}
