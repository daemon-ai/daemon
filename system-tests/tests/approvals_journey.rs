// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Jarrad Hope

//! E2 (TOOL-8) — the approvals-inbox decide→resume journey, end to end over the real socket.
//!
//! The existing `hitl.rs` scenarios prove the LIVE in-stream gate (a `submit` turn parks a
//! `SessionPayload::Request(Approval)` answered with `Respond`). This journey proves the OTHER
//! HITL surface — the durable **approvals inbox** (`ApprovalsPending` list + `ApprovalDecide`) that
//! the GUI's `DaemonApprovalsInbox` drives — carrying the wire-v29 deny-with-reason through:
//!
//!   SetSessionMode{Ask} → Assign  (a durable, operator-narrowed session drives + gates)
//!     → ApprovalsPending           (the parked approval appears in the inbox)
//!     → ApprovalDecide{allow, reason?}  (decide FROM the inbox — deny-with-reason AND approve)
//!     → the parked session resumes and reaches `Completed`.
//!
//! This is the socket-level companion to daemon-node's `approval_deny_reason.rs` conformance test
//! (which asserts the operator's reason reaches the model's next request in-process); here we prove
//! the same cycle crosses the length-framed CBOR socket the GUI inbox uses. Hermetic: the daemon
//! runs the binary-internal scripted provider (`DAEMON_MODEL_PROVIDER=scripted`) — no network, no
//! credentials.
//!
//! A durable session (not a live `submit`) is required so the gate lands in the durable inbox, and
//! it must be PROFILE-BOUND for the `Ask` overlay to take effect — a bare autonomous durable engine
//! forces `AutoAllow` and never gates (see `engine_incarnation::resolve_session_profile` + the
//! `approval_deny_reason` conformance note). The socket setup that mirrors the conformance fixture's
//! store-level seeding is:
//!   SessionCreate{profile:None}  → mints a durable row bound to the active default profile (claims
//!                                  the LIVE lifecycle);
//!   Cancel                       → releases that live claim (the durable row + bound-profile meta
//!                                  persist), so the id is free for the durable surface;
//!   SetSessionMode{Ask}          → narrows the bound session's overlay to `Ask`;
//!   Assign                       → claims the durable lifecycle + wakes it; the scripted `fs` write
//!                                  now gates under `Ask` and parks a durable approval in the inbox.
//!
//! Skips when `CLIENT`/`DAEMON` binaries are unset (e.g. CI didn't build them).

use std::path::PathBuf;
use std::time::{Duration, Instant};

use daemon_api::{ApiRequest, ApiResponse, ApprovalMode, SessionState};
use daemon_common::SessionId;
use daemon_system_tests::{api_call, Bins, Daemon};

/// The scripted provider's replay: write a file (gated → parks an Approval under Ask), then finish.
/// Whether the write is approved (runs) or denied (a tool error, carrying the operator's reason, is
/// injected), the next step is the final text — so the turn always resolves to `Completed`.
const APPROVAL_SCRIPT: &str = r#"[{"call":"fs","args":"{\"op\":\"write\",\"path\":\"note.txt\",\"content\":\"hi\"}"},{"final":"file written after approval"}]"#;

fn daemon_bin() -> Option<PathBuf> {
    std::env::var_os("DAEMON_BIN").map(PathBuf::from)
}

/// Start a daemon whose default provider replays `script` (the scripted-provider HITL trigger).
fn scripted_daemon(script: &str) -> Option<Daemon> {
    let bins = Bins::from_env().ok()?;
    Daemon::start_with_env(
        &bins,
        &[
            ("DAEMON_MODEL_PROVIDER", "scripted".into()),
            ("DAEMON_MOCK_SCRIPT", script.into()),
        ],
    )
    .ok()
}

/// Set up a profile-bound durable session narrowed to `Ask`, then `Assign` to wake it so the
/// scripted `fs` write gates and parks a durable approval. The overlay must be `Ask` and the session
/// profile-bound BEFORE the engine drives, so the order is: SessionCreate (bind) → Cancel (free the
/// live claim) → SetSessionMode{Ask} → Assign.
fn drive_until_parked(daemon: &Daemon, session: &SessionId) -> String {
    // Bind the active default profile to the (durable) session row. SessionCreate claims the LIVE
    // lifecycle, so it must be released before the durable Assign below.
    let create = ApiRequest::SessionCreate {
        session: Some(session.clone()),
        profile: None,
    };
    assert!(
        matches!(
            api_call(&daemon.socket, &create).expect("SessionCreate"),
            ApiResponse::SessionCreated { .. }
        ),
        "SessionCreate should mint a profile-bound durable row"
    );
    assert!(
        matches!(
            api_call(
                &daemon.socket,
                &ApiRequest::Cancel {
                    session: session.clone()
                }
            )
            .expect("Cancel"),
            ApiResponse::Ok
        ),
        "Cancel should release the live lifecycle claim (keeping the durable row + bound profile)"
    );

    let ask = ApiRequest::SetSessionMode {
        session: session.clone(),
        mode: ApprovalMode::Ask,
    };
    assert!(
        matches!(
            api_call(&daemon.socket, &ask).expect("SetSessionMode"),
            ApiResponse::Ok
        ),
        "SetSessionMode{{Ask}} should be accepted over the local (system-trust) socket"
    );
    let assign = ApiRequest::Assign {
        session: session.clone(),
    };
    assert!(
        matches!(
            api_call(&daemon.socket, &assign).expect("Assign"),
            ApiResponse::Ok
        ),
        "Assign should wake the durable session"
    );

    // Poll the durable inbox until the gated write parks its approval (or time out).
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let pending = ApiRequest::ApprovalsPending {
            session: Some(session.clone()),
            after: None,
        };
        if let ApiResponse::Approvals(page) =
            api_call(&daemon.socket, &pending).expect("ApprovalsPending")
        {
            if let Some(first) = page.items.first() {
                return first.request_id.clone();
            }
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for a parked approval in the inbox for {session}\ndaemon log:\n{}",
            daemon.log_contents()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Block until `session` reaches `Completed` (the deny path resolves the same as approve — a decided
/// gate never strands the session).
fn wait_completed(daemon: &Daemon, session: &SessionId) {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let ApiResponse::Sessions(list) =
            api_call(&daemon.socket, &ApiRequest::Sessions).expect("Sessions")
        {
            if list
                .iter()
                .any(|s| &s.session == session && s.state == SessionState::Completed)
            {
                return;
            }
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {session} to complete after the decision\ndaemon log:\n{}",
            daemon.log_contents()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// E2 approve path: the parked approval, read from the inbox, is APPROVED via `ApprovalDecide` — the
/// gated write runs and the durable session completes.
#[test]
fn inbox_approve_resumes_the_parked_session() {
    if daemon_bin().is_none() {
        eprintln!("skipping inbox_approve_resumes_the_parked_session: DAEMON_BIN unset");
        return;
    }
    let Some(daemon) = scripted_daemon(APPROVAL_SCRIPT) else {
        eprintln!("skipping inbox_approve_resumes_the_parked_session: daemon did not start");
        return;
    };

    let session = SessionId::new("e2e-inbox-approve");
    let request_id = drive_until_parked(&daemon, &session);

    let decide = ApiRequest::ApprovalDecide {
        session: session.clone(),
        request_id,
        allow: true,
        allow_permanent: false,
        reason: None,
    };
    assert!(
        matches!(
            api_call(&daemon.socket, &decide).expect("ApprovalDecide(approve)"),
            ApiResponse::Ok
        ),
        "approving from the inbox should be accepted"
    );

    wait_completed(&daemon, &session);
}

/// E2 deny-with-reason path (wire v29): the parked approval is DENIED with an operator `reason` via
/// `ApprovalDecide`. The reason rides the decision (proven to reach the model verbatim by
/// daemon-node's `approval_deny_reason` conformance test); here we prove the deny-with-reason
/// crosses the socket and the session still resumes to `Completed` (the deny never strands it).
#[test]
fn inbox_deny_with_reason_resumes_the_parked_session() {
    if daemon_bin().is_none() {
        eprintln!("skipping inbox_deny_with_reason_resumes_the_parked_session: DAEMON_BIN unset");
        return;
    }
    let Some(daemon) = scripted_daemon(APPROVAL_SCRIPT) else {
        eprintln!(
            "skipping inbox_deny_with_reason_resumes_the_parked_session: daemon did not start"
        );
        return;
    };

    let session = SessionId::new("e2e-inbox-deny");
    let request_id = drive_until_parked(&daemon, &session);

    let decide = ApiRequest::ApprovalDecide {
        session: session.clone(),
        request_id,
        allow: false,
        allow_permanent: false,
        reason: Some("note.txt is generated — write to scratch/notes.txt instead".into()),
    };
    assert!(
        matches!(
            api_call(&daemon.socket, &decide).expect("ApprovalDecide(deny+reason)"),
            ApiResponse::Ok
        ),
        "deny-with-reason from the inbox should be accepted (wire v29)"
    );

    wait_completed(&daemon, &session);
}
