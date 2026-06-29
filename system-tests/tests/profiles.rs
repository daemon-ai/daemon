// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Jarrad Hope

//! Profiles & agents scenarios (user story 02): the client lists real profiles (PRO-1), binds a
//! turn to a chosen profile (PRO-5), and per-profile credential isolation holds (PRO-6).

use std::path::PathBuf;
use std::time::Duration;

use daemon_api::{ApiRequest, ApiResponse};
use daemon_system_tests::{
    api_call, run_gui_chat_as_profile, run_gui_onboard, run_gui_profile, run_turn_as_profile, Bins,
    Daemon, RecordingProxy,
};

fn daemon_bin() -> Option<PathBuf> {
    std::env::var_os("DAEMON_BIN").map(PathBuf::from)
}
fn gui_bin() -> Option<PathBuf> {
    std::env::var_os("CLIENT_GUI_BIN").map(PathBuf::from)
}

/// The node's active profile id (its credential key) over `socket`.
fn active_profile_id(socket: &std::path::Path) -> String {
    match api_call(socket, &ApiRequest::ProfileList).expect("ProfileList round-trips") {
        ApiResponse::Profiles(profiles) => profiles
            .iter()
            .find(|p| p.is_active)
            .or_else(|| profiles.first())
            .map(|p| p.id.to_string())
            .expect("the node has at least one profile"),
        other => panic!("ProfileList did not return Profiles: {other:?}"),
    }
}

/// True if a profile with `id` is present in the node's list.
fn profile_listed(socket: &std::path::Path, id: &str) -> bool {
    match api_call(socket, &ApiRequest::ProfileList).expect("ProfileList round-trips") {
        ApiResponse::Profiles(profiles) => profiles.iter().any(|p| p.id.as_str() == id),
        other => panic!("ProfileList did not return Profiles: {other:?}"),
    }
}

/// A profile's model string (via ProfileGet), or empty if unknown.
fn profile_model(socket: &std::path::Path, id: &str) -> String {
    match api_call(socket, &ApiRequest::ProfileGet { id: id.into() }).expect("ProfileGet round-trips")
    {
        ApiResponse::Profile(Some(spec)) => spec.model,
        _ => String::new(),
    }
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

/// PRO-2 / PRO-3: the client creates a profile (ProfileCreate) and edits it (ProfileUpdate); the
/// node persists the new spec, observable via ProfileGet.
#[test]
fn gui_creates_and_edits_a_profile() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping gui_creates_and_edits_a_profile: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping gui_creates_and_edits_a_profile: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_profile(&gui, &proxy.socket, "work", "gpt-4o", "Be terse.", 15000)
        .expect("gui runs");
    assert!(run.stdout.contains("DAEMON_APP_READY ok"), "client did not reach ready");

    assert!(
        proxy.requests().iter().any(|r| matches!(r, ApiRequest::ProfileCreate { .. })),
        "expected a ProfileCreate; frames: {:?}",
        proxy.requests()
    );
    assert!(
        proxy.requests().iter().any(|r| matches!(r, ApiRequest::ProfileUpdate { .. })),
        "expected a ProfileUpdate; frames: {:?}",
        proxy.requests()
    );

    assert!(profile_listed(&daemon.socket, "work"), "the created profile should be listed");
    match api_call(&daemon.socket, &ApiRequest::ProfileGet { id: "work".into() })
        .expect("ProfileGet round-trips")
    {
        ApiResponse::Profile(Some(spec)) => {
            assert_eq!(spec.model, "gpt-4o", "the edit should persist the model");
            assert_eq!(spec.system_prompt, "Be terse.", "the edit should persist the prompt");
        }
        other => panic!("ProfileGet did not return the edited spec: {other:?}"),
    }
}

/// PRO-2 clone / PRO-4 delete: cloning the active profile yields a new listed profile that is a
/// copy of its spec; deleting it removes it from the list.
#[test]
fn profile_clone_then_delete() {
    if daemon_bin().is_none() {
        eprintln!("skipping profile_clone_then_delete: DAEMON_BIN unset");
        return;
    }
    let daemon = Daemon::start().expect("daemon becomes ready");
    let source = active_profile_id(&daemon.socket);

    match api_call(
        &daemon.socket,
        &ApiRequest::ProfileClone {
            source: source.clone(),
            new_id: "work-clone".into(),
        },
    )
    .expect("ProfileClone round-trips")
    {
        ApiResponse::Error(e) => panic!("ProfileClone failed: {e:?}"),
        _ => {}
    }
    assert!(profile_listed(&daemon.socket, "work-clone"), "the clone should be listed");

    // The clone is a copy of the source's spec (same provider/model), not a live link.
    let (src_model, clone_model) = (
        profile_model(&daemon.socket, &source),
        profile_model(&daemon.socket, "work-clone"),
    );
    assert_eq!(src_model, clone_model, "the clone should copy the source's model");

    match api_call(&daemon.socket, &ApiRequest::ProfileDelete { id: "work-clone".into() })
        .expect("ProfileDelete round-trips")
    {
        ApiResponse::Ok => {}
        other => panic!("ProfileDelete did not return Ok: {other:?}"),
    }
    assert!(!profile_listed(&daemon.socket, "work-clone"), "the deleted clone should be gone");
}

/// PRO-7: export the active profile as a portable Distribution, then import it under a new id (the
/// new profile lists). PRO-8: an edit appends a revision, ProfileHistory lists it, and ProfileRevert
/// rolls the profile back - all against the real daemon's revision log.
#[test]
fn profile_export_import_history_revert() {
    let bins = match Bins::from_env() {
        Ok(b) => b,
        Err(e) => {
            eprintln!("skipping profile_export_import_history_revert: {e}");
            return;
        }
    };
    // Profile versioning (ProfileHistory/Revert) is bound only on a durable node (the in-memory
    // default hosts no revision log), so run against the SQLite store backend.
    let daemon = Daemon::start_with_env(&bins, &[("DAEMON_STORE", "sqlite".into())])
        .expect("durable daemon becomes ready");
    let active = active_profile_id(&daemon.socket);

    // PRO-7 export: the active profile serializes to a Distribution carrying its spec.
    let dist = match api_call(&daemon.socket, &ApiRequest::ProfileExport { id: active.clone() })
        .expect("ProfileExport round-trips")
    {
        ApiResponse::Distribution(dist) => {
            assert_eq!(dist.profile.id, active, "the distribution carries the exported profile");
            dist
        }
        other => panic!("ProfileExport did not return a Distribution: {other:?}"),
    };

    // PRO-7 import: bring the distribution back under a new id; the new profile lists. (The GUI's
    // export->file->import file round-trip is covered by the daemon-app unit test.)
    match api_call(
        &daemon.socket,
        &ApiRequest::ProfileImport {
            dist,
            new_id: Some("exported-copy".into()),
        },
    )
    .expect("ProfileImport round-trips")
    {
        ApiResponse::ProfileId(id) => assert_eq!(id, "exported-copy", "import returns the new id"),
        other => panic!("ProfileImport did not return a ProfileId: {other:?}"),
    }
    assert!(profile_listed(&daemon.socket, "exported-copy"), "the imported profile should list");

    // PRO-8: an edit appends a revision. Re-fetch the spec, tweak the model, and update.
    let mut spec = match api_call(&daemon.socket, &ApiRequest::ProfileGet { id: active.clone() })
        .expect("ProfileGet round-trips")
    {
        ApiResponse::Profile(Some(spec)) => spec,
        other => panic!("ProfileGet did not return the active spec: {other:?}"),
    };
    spec.model = "edited-model".into();
    match api_call(&daemon.socket, &ApiRequest::ProfileUpdate { spec }).expect("ProfileUpdate")
    {
        ApiResponse::Ok => {}
        other => panic!("ProfileUpdate did not return Ok: {other:?}"),
    }

    // ProfileHistory lists the revision log (oldest first); revert to its first revision.
    let revs = match api_call(&daemon.socket, &ApiRequest::ProfileHistory { id: active.clone() })
        .expect("ProfileHistory round-trips")
    {
        ApiResponse::Revisions(revs) => revs,
        other => panic!("ProfileHistory did not return Revisions: {other:?}"),
    };
    assert!(!revs.is_empty(), "the edited profile should have at least one revision");
    let first_seq = revs.first().expect("a revision").seq;

    match api_call(
        &daemon.socket,
        &ApiRequest::ProfileRevert {
            id: active.clone(),
            seq: first_seq,
        },
    )
    .expect("ProfileRevert round-trips")
    {
        ApiResponse::Ok => {}
        other => panic!("ProfileRevert did not return Ok: {other:?}"),
    }
}

/// PRO-6 (full A-vs-B, opt-in real key): clone the configured default into two profiles, key only
/// one; a turn under the keyed profile completes while the other fails - true per-profile credential
/// isolation across two identically-configured profiles (only the credential differs).
#[test]
fn credential_isolation_a_vs_b() {
    let Some(key) = anthropic_key() else {
        eprintln!("skipping credential_isolation_a_vs_b: ANTHROPIC_API_KEY unset");
        return;
    };
    let bins = match Bins::from_env() {
        Ok(b) => b,
        Err(e) => {
            eprintln!("skipping credential_isolation_a_vs_b: {e}");
            return;
        }
    };
    let daemon = Daemon::start_with_env(
        &bins,
        &[
            ("DAEMON_MODEL_PROVIDER", "genai".into()),
            ("DAEMON_MODEL", "claude-haiku-4-5-20251001".into()),
        ],
    )
    .expect("daemon (genai) becomes ready");
    let source = active_profile_id(&daemon.socket);

    // Two profiles cloned from the configured default: identical provider/model, differing only in
    // which one has a stored credential.
    for new_id in ["work", "personal"] {
        match api_call(
            &daemon.socket,
            &ApiRequest::ProfileClone {
                source: source.clone(),
                new_id: new_id.into(),
            },
        )
        .expect("ProfileClone round-trips")
        {
            ApiResponse::Error(e) => panic!("ProfileClone failed: {e:?}"),
            _ => {}
        }
    }
    match api_call(
        &daemon.socket,
        &ApiRequest::CredentialSet {
            profile: "work".into(),
            secret: key,
        },
    )
    .expect("CredentialSet round-trips")
    {
        ApiResponse::Ok => {}
        other => panic!("CredentialSet did not return Ok: {other:?}"),
    }

    let work = run_turn_as_profile(
        &daemon.socket,
        "iso-work",
        "Reply with exactly: pong.",
        Some("work"),
        Duration::from_secs(90),
    )
    .expect("work turn drives");
    assert!(
        work.completed && !work.final_text.trim().is_empty(),
        "expected the keyed profile to complete a turn.\nturn: {work:?}\ndaemon log:\n{}",
        daemon.log_contents()
    );

    let personal = run_turn_as_profile(
        &daemon.socket,
        "iso-personal",
        "Reply with exactly: pong.",
        Some("personal"),
        Duration::from_secs(60),
    )
    .expect("personal turn drives");
    assert!(
        !personal.completed,
        "expected the unkeyed profile to FAIL (no credential), but it completed: {personal:?}\ndaemon log:\n{}",
        daemon.log_contents()
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
