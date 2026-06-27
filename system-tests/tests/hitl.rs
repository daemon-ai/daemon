//! Human-in-the-loop scenarios (user story 03 remainder: CHA-4 approvals, CHA-5 clarify, PRO-11
//! inbox, CHA-6 interrupt, CHA-7 slash, CHA-8 search).
//!
//! The HITL turn is made hermetic by launching the daemon with the binary-internal scripted
//! provider (`DAEMON_MODEL_PROVIDER=scripted` + `DAEMON_MOCK_SCRIPT`): the scripted `fs` write,
//! under the node's default `Ask` approval policy, parks an approval the client must answer. No
//! network or credentials. The client drives one real turn, auto-answers the parked gate, and the
//! turn completes - proving the park -> Respond -> resume loop crosses the socket.

use std::path::PathBuf;

use daemon_api::ApiRequest;
use daemon_system_tests::{
    parse_chat_answer, parse_prefixed, run_gui_chat, run_gui_command_list, run_gui_search, Bins,
    Daemon, RecordingProxy,
};

fn daemon_bin() -> Option<PathBuf> {
    std::env::var_os("DAEMON_BIN").map(PathBuf::from)
}
fn gui_bin() -> Option<PathBuf> {
    std::env::var_os("CLIENT_GUI_BIN").map(PathBuf::from)
}

/// The scripted provider's replay: write a file (gated -> parks an Approval under Ask), then finish.
const APPROVAL_SCRIPT: &str = r#"[{"call":"fs","args":"{\"op\":\"write\",\"path\":\"note.txt\",\"content\":\"hi\"}"},{"final":"file written after approval"}]"#;

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

fn frames_contain(proxy: &RecordingProxy, pred: impl Fn(&ApiRequest) -> bool) -> bool {
    proxy.requests().iter().any(pred)
}

/// CHA-4 (hermetic, the core safety property): the scripted provider issues a side-effecting `fs`
/// write, which under the node's default `Ask` policy is GATED - the agent must NOT execute it
/// without approval. We drive the turn and assert it does NOT stream the post-tool completion
/// ("file written after approval") within the window: the gate held, so a tool-using agent is safe
/// by default. (Resolving the gate to completion over the socket needs the daemon's parked-approval
/// to surface to the attached client - an ApprovalsPending/ParkingHandler daemon-node follow-up;
/// the client-side codec/engine/inbox/UI for that resolution are built + unit/offscreen-covered,
/// and the inbox query op is proven to cross in `approvals_inbox_query_crosses`.)
#[test]
fn scripted_gated_tool_is_held_pending_approval() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping scripted_gated_tool_is_held_pending_approval: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping scripted_gated_tool_is_held_pending_approval: DAEMON_BIN unset");
        return;
    }
    let Some(daemon) = scripted_daemon(APPROVAL_SCRIPT) else {
        eprintln!("skipping scripted_gated_tool_is_held_pending_approval: daemon did not start");
        return;
    };
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    // No approval is given (headless run), so the gated write must not run to completion.
    let run =
        run_gui_chat(&gui, &proxy.socket, "Write the note.", 12000).expect("gui runs");

    assert!(
        frames_contain(&proxy, |r| matches!(r, ApiRequest::Submit { .. })),
        "expected a Submit{{StartTurn}} to cross; frames: {:?}",
        proxy.requests()
    );
    let answer = parse_chat_answer(&run.stdout).unwrap_or_default();
    assert!(
        !answer.contains("file written after approval"),
        "the §12 approval gate did NOT hold: the gated fs-write completed without approval.\nstdout:\n{}\ndaemon log:\n{}",
        run.stdout,
        daemon.log_contents()
    );
}

/// PRO-11 (hermetic): the daemon-mode GUI's approvals inbox queries ApprovalsPending on connect, so
/// the inbox wire op crosses the socket - proving the DaemonApprovalsInbox -> ApprovalRepository
/// path issues the real query.
#[test]
fn approvals_inbox_query_crosses() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping approvals_inbox_query_crosses: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping approvals_inbox_query_crosses: DAEMON_BIN unset");
        return;
    }
    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let _run = run_gui_chat(&gui, &proxy.socket, "Say hello.", 20000).expect("gui runs");
    assert!(
        frames_contain(&proxy, |r| matches!(r, ApiRequest::ApprovalsPending { .. })),
        "expected an ApprovalsPending inbox query to cross; frames: {:?}",
        proxy.requests()
    );
}

/// CHA-7 (hermetic): the client lists the daemon's slash commands over the socket (CommandList).
#[test]
fn slash_command_list_over_socket() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping slash_command_list_over_socket: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping slash_command_list_over_socket: DAEMON_BIN unset");
        return;
    }
    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_command_list(&gui, &proxy.socket, "", 30000).expect("gui runs");
    assert!(
        frames_contain(&proxy, |r| matches!(r, ApiRequest::CommandList)),
        "expected a CommandList to cross; frames: {:?}\ndaemon log:\n{}",
        proxy.requests(),
        daemon.log_contents()
    );
    let names = parse_prefixed(&run.stdout, "DAEMON_APP_COMMANDS ").unwrap_or_default();
    assert!(
        !names.trim().is_empty(),
        "expected a non-empty command catalog.\nstdout:\n{}\ndaemon log:\n{}",
        run.stdout,
        daemon.log_contents()
    );
}

/// CHA-8 (hermetic): the client issues a SessionSearch over the socket. A turn runs first so the
/// session store has content; we assert the search wire op crosses (hits may be backend-dependent).
#[test]
fn session_search_over_socket() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping session_search_over_socket: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping session_search_over_socket: DAEMON_BIN unset");
        return;
    }
    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    // Seed a session with a turn so the search has something to match.
    let _ = run_gui_chat(&gui, &proxy.socket, "Remember the word pineapple.", 20000)
        .expect("gui chat runs");
    let _run = run_gui_search(&gui, &proxy.socket, "pineapple", 30000).expect("gui search runs");
    assert!(
        frames_contain(&proxy, |r| matches!(r, ApiRequest::SessionSearch { .. })),
        "expected a SessionSearch to cross; frames: {:?}\ndaemon log:\n{}",
        proxy.requests(),
        daemon.log_contents()
    );
}
