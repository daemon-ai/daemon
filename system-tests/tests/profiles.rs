//! Profiles & agents scenarios (user story 02): the client lists real profiles (PRO-1), binds a
//! turn to a chosen profile (PRO-5), and per-profile credential isolation holds (PRO-6).

use std::path::PathBuf;
use std::time::Duration;

use daemon_api::{ApiRequest, ApiResponse};
use daemon_system_tests::{
    run_gui_chat_as_profile, run_gui_onboard, run_turn_as_profile, Bins, Daemon, RecordingProxy,
};

fn daemon_bin() -> Option<PathBuf> {
    std::env::var_os("DAEMON_BIN").map(PathBuf::from)
}
fn gui_bin() -> Option<PathBuf> {
    std::env::var_os("CLIENT_GUI_BIN").map(PathBuf::from)
}

fn anthropic_key() -> Option<String> {
    if let Ok(k) = std::env::var("ANTHROPIC_API_KEY") {
        if !k.trim().is_empty() {
            return Some(k.trim().to_string());
        }
    }
    let dotenv = PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent()?.join(".env");
    let text = std::fs::read_to_string(dotenv).ok()?;
    for line in text.lines() {
        if let Some(v) = line.trim().strip_prefix("ANTHROPIC_API_KEY=") {
            let v = v.trim().trim_matches('"').trim_matches('\'');
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

/// PRO-1: the client requests ProfileList on connect and receives the node's real profiles (the
/// default profile flagged active) - not mock seed data.
#[test]
fn gui_lists_real_profiles() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping gui_lists_real_profiles: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping gui_lists_real_profiles: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    // Onboarding settles the event loop, so the on-ready ProfileList flushes through the proxy.
    let run = run_gui_onboard(&gui, &proxy.socket, "anthropic", "sk-ant-test", 10000)
        .expect("gui runs");
    assert!(run.stdout.contains("DAEMON_APP_READY ok"), "client did not reach ready");

    assert!(
        proxy.requests().iter().any(|r| matches!(r, ApiRequest::ProfileList)),
        "expected the client to request ProfileList; frames: {:?}",
        proxy.requests()
    );
    let has_real_default = proxy.responses().iter().any(|r| match r {
        ApiResponse::Profiles(profiles) => profiles.iter().any(|p| p.is_active),
        _ => false,
    });
    assert!(
        has_real_default,
        "expected a Profiles response with an active default profile; frames: {:?}",
        proxy.frames()
    );
}

/// PRO-5: a turn bound to a chosen profile carries it on the wire (Submit{ profile: Some(..) }), so
/// the new session runs under that agent.
#[test]
fn profile_scoped_submit_binds_profile() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping profile_scoped_submit_binds_profile: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping profile_scoped_submit_binds_profile: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let _run = run_gui_chat_as_profile(&gui, &proxy.socket, "Say hello.", "scratch", 20000)
        .expect("gui runs");

    let bound = proxy.requests().iter().any(|r| {
        matches!(r, ApiRequest::Submit { profile: Some(p), .. } if format!("{p:?}").contains("scratch"))
    });
    assert!(
        bound,
        "expected Submit to carry profile 'scratch'; frames: {:?}",
        proxy.requests()
    );
}

/// PRO-6 / CON-8 (opt-in, real key): a turn on the active (genai) profile FAILS while it has no
/// stored credential, and SUCCEEDS once a key is stored for that profile - inference is gated by the
/// per-profile credential. (Full A-vs-B isolation across two configured profiles additionally needs
/// ProfileCreate, PRO-2, which is a later slice; this proves the credential gate on the one profile
/// the node ships with.)
#[test]
fn credential_gates_inference_per_profile() {
    let Some(key) = anthropic_key() else {
        eprintln!("skipping credential_gates_inference_per_profile: ANTHROPIC_API_KEY unset");
        return;
    };
    let bins = match Bins::from_env() {
        Ok(b) => b,
        Err(e) => {
            eprintln!("skipping credential_gates_inference_per_profile: {e}");
            return;
        }
    };

    // genai + a real model, but NO ANTHROPIC_API_KEY in the daemon env: only a stored per-profile
    // credential can provision a turn, so the gate is observable.
    let daemon = Daemon::start_with_env(
        &bins,
        &[
            ("DAEMON_MODEL_PROVIDER", "genai".into()),
            ("DAEMON_MODEL", "claude-haiku-4-5-20251001".into()),
        ],
    )
    .expect("daemon (genai) becomes ready");

    // The active profile id the node ships with (its credential key).
    let active_profile = match daemon_system_tests::api_call(&daemon.socket, &ApiRequest::ProfileList)
        .expect("ProfileList round-trips")
    {
        ApiResponse::Profiles(profiles) => profiles
            .iter()
            .find(|p| p.is_active)
            .or_else(|| profiles.first())
            .map(|p| p.id.to_string())
            .expect("the node has at least one profile"),
        other => panic!("ProfileList did not return Profiles: {other:?}"),
    };

    // Before any credential: a turn must FAIL (no provider, CON-8).
    let unprovisioned = run_turn_as_profile(
        &daemon.socket,
        "gate-unprovisioned",
        "Reply with exactly: pong.",
        None,
        Duration::from_secs(60),
    )
    .expect("unprovisioned turn drives");
    assert!(
        !unprovisioned.completed,
        "expected an unprovisioned turn to FAIL, but it completed: {unprovisioned:?}\ndaemon log:\n{}",
        daemon.log_contents()
    );

    // Store the key for the active profile.
    match daemon_system_tests::api_call(
        &daemon.socket,
        &ApiRequest::CredentialSet {
            profile: active_profile.clone(),
            secret: key,
        },
    )
    .expect("CredentialSet round-trips")
    {
        ApiResponse::Ok => {}
        other => panic!("CredentialSet did not return Ok: {other:?}"),
    }

    // Now the same turn resolves the credential and completes.
    let provisioned = run_turn_as_profile(
        &daemon.socket,
        "gate-provisioned",
        "Reply with exactly: pong.",
        None,
        Duration::from_secs(90),
    )
    .expect("provisioned turn drives");
    assert!(
        provisioned.completed && !provisioned.final_text.trim().is_empty(),
        "expected the provisioned profile to complete a turn.\nturn: {provisioned:?}\ndaemon log:\n{}",
        daemon.log_contents()
    );
}
