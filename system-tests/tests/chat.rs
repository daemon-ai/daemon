//! Basic-chat scenarios (user story 03, CHA-1 / CHA-2): a real turn crosses the socket - the client
//! sends Submit{StartTurn} and consumes the daemon's AgentEvent stream via Subscribe, rather than
//! the local TurnController simulator.
//!
//! The hermetic variants run against the default (mock-provider) daemon so they are deterministic
//! and need no credentials. An opt-in variant drives a real Anthropic turn when a key is available.

use std::path::PathBuf;

use daemon_api::{ApiRequest, ApiResponse};
use daemon_common::SessionId;
use daemon_system_tests::{
    api_call, parse_chat_answer, run_gui_chat, run_gui_onboard, run_tui_chat, Bins, Daemon,
    RecordingProxy,
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

fn assert_turn_crossed(proxy: &RecordingProxy) {
    let frames = proxy.requests();
    assert!(
        frames.iter().any(|r| matches!(r, ApiRequest::Submit { .. })),
        "expected a Submit{{StartTurn}} to cross the socket; frames: {:?}",
        frames
    );
    assert!(
        frames.iter().any(|r| matches!(r, ApiRequest::Subscribe { .. })),
        "expected a Subscribe to cross the socket; frames: {:?}",
        frames
    );
}

/// CHA-1 / CHA-2 (hermetic): the GUI sends a real turn and streams the mock provider's reply.
#[test]
fn gui_chat_streams_a_real_turn() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping gui_chat_streams_a_real_turn: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping gui_chat_streams_a_real_turn: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_chat(&gui, &proxy.socket, "Say hello.", 20000).expect("gui runs");
    assert_turn_crossed(&proxy);
    let answer = parse_chat_answer(&run.stdout).unwrap_or_default();
    assert!(
        !answer.trim().is_empty(),
        "expected streamed assistant text from the turn.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );
    eprintln!("gui mock answer: {:?}", answer.trim());
}

/// CHA-1 / CHA-2 (hermetic): the TUI variant.
#[test]
fn tui_chat_streams_a_real_turn() {
    let Some(tui) = tui_bin() else {
        eprintln!("skipping tui_chat_streams_a_real_turn: CLIENT_TUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping tui_chat_streams_a_real_turn: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_tui_chat(&tui, &proxy.socket, "Say hello.", (40, 120), 20000).expect("tui runs");
    assert_turn_crossed(&proxy);
    let answer = parse_chat_answer(&run.stdout).unwrap_or_default();
    assert!(
        !answer.trim().is_empty(),
        "expected streamed assistant text from the turn.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );
    eprintln!("tui mock answer: {:?}", answer.trim());
}

/// CHA-9 (resume): a client turn leaves durable, replayable transcript on the daemon. Resume is the
/// same Subscribe path the live turn uses, re-issued from seq 0 - so re-subscribing a session that
/// had a turn returns its merged log (the user command + the assistant's events). This proves the
/// durable-continuity contract the client's resume hydration builds on.
#[test]
fn turn_leaves_resumable_transcript() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping turn_leaves_resumable_transcript: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping turn_leaves_resumable_transcript: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_chat(&gui, &proxy.socket, "Say hello.", 20000).expect("gui runs");
    assert!(
        !parse_chat_answer(&run.stdout).unwrap_or_default().trim().is_empty(),
        "the turn did not stream"
    );

    // The session id the client minted for this turn (from the Submit it sent).
    let session = proxy
        .requests()
        .iter()
        .find_map(|r| match r {
            ApiRequest::Submit { session, .. } => Some(session.as_str().to_string()),
            _ => None,
        })
        .expect("a Submit crossed the proxy");

    // Resume = re-Subscribe from seq 0; the durable merged log replays the turn.
    let view = match api_call(
        &daemon.socket,
        &ApiRequest::Subscribe {
            session: SessionId::new(&session),
            after_seq: 0,
            max: 256,
        },
    )
    .expect("Subscribe round-trips")
    {
        ApiResponse::LogPage(view) => view,
        other => panic!("Subscribe did not return LogPage: {other:?}"),
    };
    assert!(
        !view.entries.is_empty(),
        "expected the resumed session's log to replay the turn; daemon log:\n{}",
        daemon.log_contents()
    );
}

/// CHA-1 / CHA-2 end-to-end with a REAL provider (opt-in): skipped unless ANTHROPIC_API_KEY is
/// available. The daemon runs the genai provider + an Anthropic model; the client drives one real
/// turn and asserts a non-empty streamed reply.
#[test]
fn gui_chat_real_anthropic_turn() {
    let Some(key) = anthropic_key() else {
        eprintln!("skipping gui_chat_real_anthropic_turn: ANTHROPIC_API_KEY unset (env or .env)");
        return;
    };
    let Some(gui) = gui_bin() else {
        eprintln!("skipping gui_chat_real_anthropic_turn: CLIENT_GUI_BIN unset");
        return;
    };
    let bins = match Bins::from_env() {
        Ok(b) => b,
        Err(e) => {
            eprintln!("skipping gui_chat_real_anthropic_turn: {e}");
            return;
        }
    };

    let daemon = Daemon::start_with_env(
        &bins,
        &[
            ("DAEMON_MODEL_PROVIDER", "genai".into()),
            ("DAEMON_MODEL", "claude-haiku-4-5-20251001".into()),
            ("ANTHROPIC_API_KEY", key.clone()),
        ],
    )
    .expect("daemon (genai) becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    // Store the provider key on the active profile first (persists in the daemon for this run); the
    // engine acquires the credential from the per-profile store, not the process env.
    let onboard =
        run_gui_onboard(&gui, &proxy.socket, "anthropic", &key, 20000).expect("gui onboards");
    assert!(
        onboard.stdout.contains("DAEMON_APP_READY ok"),
        "onboarding did not reach ready before the real turn.\nstdout:\n{}\ndaemon log:\n{}",
        onboard.stdout,
        daemon.log_contents()
    );

    let run = run_gui_chat(&gui, &proxy.socket, "Reply with exactly the single word: pong.", 90000)
        .expect("gui runs");
    assert_turn_crossed(&proxy);
    let answer = parse_chat_answer(&run.stdout).unwrap_or_default();
    assert!(
        !answer.trim().is_empty(),
        "expected a real streamed answer.\nstdout:\n{}\ndaemon log:\n{}",
        run.stdout,
        daemon.log_contents()
    );
    eprintln!("gui real answer: {:?}", answer.trim());
}
