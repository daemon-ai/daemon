//! End-to-end protocol-trace scenarios. These need the real binaries (`DAEMON_BIN`,
//! `DAEMON_CLI_BIN`); they skip cleanly when those are not set so `cargo test` is still green in a
//! bare checkout. The build/CI layer points the env vars at the artifacts it built.

use std::path::PathBuf;
use std::time::Duration;

use daemon_api::{ApiRequest, ApiResponse};
use daemon_system_tests::{run_cli, Daemon, RecordingProxy};

fn have_daemon() -> bool {
    std::env::var_os("DAEMON_BIN").is_some() && std::env::var_os("DAEMON_CLI_BIN").is_some()
}

#[test]
fn daemon_starts_and_reports_ready() {
    if !have_daemon() {
        eprintln!("skipping daemon_starts_and_reports_ready: DAEMON_BIN/DAEMON_CLI_BIN unset");
        return;
    }
    let daemon = Daemon::start().expect("daemon becomes ready");
    assert!(daemon.socket.exists(), "the api socket should exist once ready");
}

#[test]
fn cli_health_round_trips_through_the_recording_proxy() {
    if !have_daemon() {
        eprintln!("skipping cli_health_round_trips_through_the_recording_proxy: binaries unset");
        return;
    }
    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let cli = PathBuf::from(std::env::var("DAEMON_CLI_BIN").unwrap());
    let (ok, _out) = run_cli(&cli, &proxy.socket, &["health"]).expect("cli runs");
    assert!(
        ok,
        "daemon-cli health failed through the proxy; daemon log:\n{}",
        daemon.log_contents()
    );

    // The thin-client value proposition: assert the exact typed request/response over the socket,
    // decoded with the daemon's own daemon-api types (no second codec).
    let request = proxy
        .wait_for_request(|r| matches!(r, ApiRequest::Health), Duration::from_secs(5))
        .expect("a Health request crossed the proxy");
    assert!(matches!(request, ApiRequest::Health));

    let saw_health_response = proxy
        .responses()
        .iter()
        .any(|r| matches!(r, ApiResponse::Health(_)));
    assert!(
        saw_health_response,
        "expected a Health response in the trace; frames: {:?}",
        proxy.frames()
    );
}
