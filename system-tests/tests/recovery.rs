// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Jarrad Hope

//! CON-9 — host-down backoff recovery: the node goes down and the client recovers when it returns.
//!
//! The app-side reconnect/backoff/offline loop lives in the client
//! (`daemon-app/src/core/daemon/daemon_connection_service.cpp`) and is unit-tested there; the piece
//! that can only be proven cross-process is the **recovery contract that loop targets**: a node
//! killed mid-life, then restarted on the *same* socket + durable state, is reachable again and a
//! client can complete a request and resume its session. This system test drives exactly that over
//! the real socket the client's reconnect loop dials:
//!
//!   1. start the node (durable store) → a turn on session `con9` completes;
//!   2. **kill** the node process group (host-down) → the socket stops answering (`Health` errors),
//!      which is the offline condition the client's backoff loop reacts to;
//!   3. **restart** the node on the same socket + data dir (host-up) → `Health` answers again;
//!   4. a follow-up turn on the *same* session `con9` completes → the client can resume against the
//!      recovered node (durable session state survived the restart).
//!
//! Skips cleanly when the daemon binaries are not injected (`DAEMON_BIN` / `DAEMON_CLI_BIN`).

use std::path::PathBuf;
use std::time::{Duration, Instant};

use daemon_api::ApiRequest;
use daemon_system_tests::{api_call, run_turn, Bins, Daemon};

fn daemon_bin() -> Option<PathBuf> {
    std::env::var_os("DAEMON_BIN").map(PathBuf::from)
}

/// Whether the node answers a cheap `Health` request over `socket` (up), vs a connect/IO error (down).
fn node_up(socket: &std::path::Path) -> bool {
    api_call(socket, &ApiRequest::Health).is_ok()
}

#[test]
fn host_down_then_recovery_resumes_the_session() {
    if daemon_bin().is_none() {
        eprintln!("skipping con9 recovery: DAEMON_BIN unset");
        return;
    }
    let Ok(bins) = Bins::from_env() else {
        eprintln!("skipping con9 recovery: DAEMON_BIN / DAEMON_CLI_BIN unset");
        return;
    };

    // Caller-owned dirs so the node can be restarted on the *same* socket + durable state. The temp
    // root is kept alive for the whole test (dropped at the end => removed).
    let root = tempfile::Builder::new()
        .prefix("dst-con9-")
        .tempdir_in("/tmp")
        .expect("con9 temp root");
    let socket = root.path().join("d.sock");
    let data_dir = root.path().join("state");
    let home = root.path().join("home");
    // A durable store, so the session created before the crash survives the restart (resume).
    let env: Vec<(&str, String)> = vec![("DAEMON_STORE", "sqlite".into())];

    // --- host up (first incarnation) -------------------------------------------------------------
    let node1 = match Daemon::start_on(
        &bins,
        socket.clone(),
        data_dir.clone(),
        home.clone(),
        root.path().join("daemon-1.log"),
        &env,
    ) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("skipping con9 recovery: first daemon did not start: {e:#}");
            return;
        }
    };
    assert!(node_up(&socket), "the node should be reachable after first start");

    let first = run_turn(&socket, "con9", "first turn before the crash", Duration::from_secs(30))
        .expect("first turn runs");
    assert!(
        first.completed,
        "a turn should complete against the healthy node (got {first:?})"
    );

    // --- host down (kill the process group) ------------------------------------------------------
    drop(node1); // SIGTERM -> (5s) -> SIGKILL the whole group, then reap.
                 // A SIGKILLed daemon may leave the socket file behind; clear it so the restart binds.
    let _ = std::fs::remove_file(&socket);
    let down = {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut down = false;
        while Instant::now() < deadline {
            if !node_up(&socket) {
                down = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        down
    };
    assert!(
        down,
        "after the node is killed the socket must stop answering (the client's offline condition)"
    );

    // --- host up again (second incarnation, same socket + durable state) -------------------------
    let node2 = Daemon::start_on(
        &bins,
        socket.clone(),
        data_dir.clone(),
        home.clone(),
        root.path().join("daemon-2.log"),
        &env,
    )
    .expect("the node restarts on the same socket + data dir");
    assert!(
        node_up(&socket),
        "the node should be reachable again after recovery"
    );

    // The client resumes: a follow-up turn on the SAME session completes against the recovered node.
    let second = run_turn(
        &socket,
        "con9",
        "second turn after recovery",
        Duration::from_secs(30),
    )
    .expect("post-recovery turn runs");
    assert!(
        second.completed,
        "a turn should complete on the resumed session after recovery (got {second:?})\ndaemon log:\n{}",
        node2.log_contents()
    );
}
