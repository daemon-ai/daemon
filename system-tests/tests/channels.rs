// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Jarrad Hope

//! Phase 6a Channels read-surface scenario (story 04: EIO-1/3/8): a fresh GUI attaches to a
//! pre-started daemon (behind a recording proxy) and runs the headless channels probe
//! (`DAEMON_APP_CHANNELS_PROBE`): refresh the transport adapters + instances, then enumerate
//! conversations. We assert the `TransportAdapters` + `TransportInstances` + `ConvList` frames
//! crossed the socket against the real NodeApi - proving the channels seam is daemon-backed, not the
//! mock. (A default daemon registers no messaging adapter, so the lists are empty and ConvList is an
//! error; the wire-crossing is what the read surface requires.)
//!
//! Skips when `CLIENT_GUI_BIN` / `DAEMON_BIN` are unset.

use std::path::PathBuf;

use daemon_api::ApiRequest;
use daemon_system_tests::{run_gui_channels, Daemon, RecordingProxy};

fn gui_bin() -> Option<PathBuf> {
    std::env::var_os("CLIENT_GUI_BIN").map(PathBuf::from)
}

fn daemon_bin() -> Option<PathBuf> {
    std::env::var_os("DAEMON_BIN").map(PathBuf::from)
}

#[test]
fn gui_channels_read_surface_wires_through() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping gui_channels_read_surface: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping gui_channels_read_surface: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_channels(&gui, &proxy.socket, 30000).expect("gui runs");
    assert!(
        run.stdout.contains("DAEMON_APP_CHANNELS adapters="),
        "no DAEMON_APP_CHANNELS adapters= line.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );

    // The adapter registry + instance + conversation queries really crossed the socket (proxy trace).
    let frames = proxy.requests();
    let has = |pred: fn(&ApiRequest) -> bool| frames.iter().any(pred);
    assert!(
        has(|r| matches!(r, ApiRequest::TransportAdapters)),
        "no TransportAdapters: {frames:?}"
    );
    assert!(
        has(|r| matches!(r, ApiRequest::TransportInstances)),
        "no TransportInstances: {frames:?}"
    );
    assert!(
        has(|r| matches!(r, ApiRequest::ConvList { .. })),
        "no ConvList: {frames:?}"
    );
}
