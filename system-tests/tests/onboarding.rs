// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Jarrad Hope

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
    run_gui_first_run_attaches, run_gui_first_run_spawns_daemon, run_gui_onboard, run_tui_onboard,
    run_tui_first_run_spawns_daemon, run_turn, Bins, Daemon, RecordingProxy,
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

/// The Anthropic key for the opt-in inference e2e: the `ANTHROPIC_API_KEY` env var, or - so the
/// developer's gitignored `.env` at the repo root works without exporting - the `ANTHROPIC_API_KEY=`
/// line from `<repo>/.env`. Returns None (test skips) when neither is present.
fn anthropic_key() -> Option<String> {
    if let Ok(k) = std::env::var("ANTHROPIC_API_KEY") {
        if !k.trim().is_empty() {
            return Some(k.trim().to_string());
        }
    }
    // system-tests/ -> repo root is one level up.
    let dotenv = PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent()?.join(".env");
    let text = std::fs::read_to_string(dotenv).ok()?;
    for line in text.lines() {
        let line = line.trim();
        if let Some(v) = line.strip_prefix("ANTHROPIC_API_KEY=") {
            let v = v.trim().trim_matches('"').trim_matches('\'');
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

fn requests_contain(proxy: &RecordingProxy, pred: impl Fn(&ApiRequest) -> bool) -> bool {
    proxy.requests().iter().any(pred)
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

/// CON-4 / CON-6 (hermetic, no real key): drive full GUI onboarding against a pre-started daemon
/// (mock provider) behind a recording proxy. Assert the credential + model discovery wire ops cross
/// the socket and setup persists - proving the client onboarding is daemon-backed end to end.
#[test]
fn gui_onboarding_credentials_and_models_wire_through() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping gui_onboarding_credentials_and_models: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping gui_onboarding_credentials_and_models: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_onboard(&gui, &proxy.socket, "anthropic", "sk-ant-test-1234", 10000)
        .expect("gui runs");
    assert!(
        run.stdout.contains("DAEMON_APP_READY ok"),
        "GUI onboarding did not reach ready.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );

    // On-ready auto-refresh: profiles + credentials + model discovery + current model.
    let saw = |label: &str, ok: bool| {
        assert!(
            ok,
            "expected {label} to cross the socket.\nframes: {:?}\ndaemon log:\n{}",
            proxy.frames(),
            daemon.log_contents()
        );
    };
    saw("ProfileList", requests_contain(&proxy, |r| matches!(r, ApiRequest::ProfileList)));
    saw("CredentialList", requests_contain(&proxy, |r| matches!(r, ApiRequest::CredentialList)));
    saw("Models", requests_contain(&proxy, |r| matches!(r, ApiRequest::Models)));
    saw("ModelCurrent", requests_contain(&proxy, |r| matches!(r, ApiRequest::ModelCurrent { .. })));
    // The pasted key was stored via CredentialSet.
    saw("CredentialSet", requests_contain(&proxy, |r| matches!(r, ApiRequest::CredentialSet { .. })));

    assert!(
        run.persisted_setup_complete(),
        "GUI onboarding did not persist setupComplete.\nconfig: {}",
        run.config_path().display()
    );
}

/// TUI variant of the hermetic onboarding wire-through.
#[test]
fn tui_onboarding_credentials_and_models_wire_through() {
    let Some(tui) = tui_bin() else {
        eprintln!("skipping tui_onboarding_credentials_and_models: CLIENT_TUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping tui_onboarding_credentials_and_models: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_tui_onboard(&tui, &proxy.socket, "anthropic", "sk-ant-test-1234", (40, 120), 10000)
        .expect("tui runs");
    assert!(
        run.stdout.contains("DAEMON_APP_READY ok"),
        "TUI onboarding did not reach ready.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );
    assert!(
        requests_contain(&proxy, |r| matches!(r, ApiRequest::CredentialSet { .. })),
        "expected the TUI to store the key via CredentialSet; frames: {:?}",
        proxy.requests()
    );
    assert!(
        requests_contain(&proxy, |r| matches!(r, ApiRequest::Models)),
        "expected the TUI to discover models; frames: {:?}",
        proxy.requests()
    );
    assert!(run.persisted_setup_complete(), "TUI onboarding did not persist setupComplete");
}

/// CON-4/6/7 end-to-end with a REAL provider (opt-in): skipped unless ANTHROPIC_API_KEY is available
/// (env or the repo `.env`). Launches the daemon with the genai provider + an Anthropic model, drives
/// GUI onboarding to store the key + discover models, then drives one real turn and asserts a
/// non-error answer streams back - proving the stored credential actually provisions inference.
#[test]
fn gui_onboarding_real_anthropic_inference() {
    let Some(key) = anthropic_key() else {
        eprintln!("skipping gui_onboarding_real_anthropic_inference: ANTHROPIC_API_KEY unset (env or .env)");
        return;
    };
    let Some(gui) = gui_bin() else {
        eprintln!("skipping gui_onboarding_real_anthropic_inference: CLIENT_GUI_BIN unset");
        return;
    };
    let bins = match Bins::from_env() {
        Ok(b) => b,
        Err(e) => {
            eprintln!("skipping gui_onboarding_real_anthropic_inference: {e}");
            return;
        }
    };

    let model = "claude-haiku-4-5-20251001"; // a cheap, fast current Anthropic model
    let daemon = Daemon::start_with_env(
        &bins,
        &[
            ("DAEMON_MODEL_PROVIDER", "genai".into()),
            ("DAEMON_MODEL", model.into()),
            ("ANTHROPIC_API_KEY", key.clone()),
        ],
    )
    .expect("daemon (genai) becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    // Onboarding stores the real key on the active profile + discovers models.
    let run =
        run_gui_onboard(&gui, &proxy.socket, "anthropic", &key, 15000).expect("gui onboards");
    assert!(
        run.stdout.contains("DAEMON_APP_READY ok"),
        "GUI onboarding (genai) did not reach ready.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );
    assert!(
        requests_contain(&proxy, |r| matches!(r, ApiRequest::CredentialSet { .. })),
        "expected the key to be stored via CredentialSet"
    );
    assert!(run.persisted_setup_complete(), "onboarding did not persist setupComplete");

    // Drive one real turn (direct to the daemon): the stored credential must provision inference.
    let turn = run_turn(
        &daemon.socket,
        "onboarding-e2e",
        "Reply with exactly the single word: pong.",
        Duration::from_secs(90),
    )
    .expect("turn drives");
    assert!(
        turn.completed && !turn.final_text.trim().is_empty(),
        "expected a real non-error answer.\nturn: {turn:?}\ndaemon log:\n{}",
        daemon.log_contents()
    );
    eprintln!("real Anthropic answer: {:?}", turn.final_text.trim());
}
