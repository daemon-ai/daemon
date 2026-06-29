// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Jarrad Hope

//! Local model track (Phase 2): search -> quant -> download -> install -> run over llama.cpp.
//!
//! The hermetic variant runs against the default daemon and proves the client wires every
//! model-track frame (ModelSearch / ModelFiles / ModelDownload / ModelCatalog / ModelDownloads):
//! the always-deterministic catalog/downloads round-trip cleanly, and the network-dependent
//! search/files/download each produce a structured response (ok or a daemon ApiError) rather than
//! hanging - so we know the client encodes + sends them and the daemon decodes + replies.
//!
//! The opt-in variant (DAEMON_VULKAN_E2E=1 + a built llama worker in DAEMON_INFER_BIN) does the
//! real thing end-to-end: discover SmolLM2-135M on the Hub, pick the smallest quant, download it,
//! catalog + activate it, then run a real local turn. CPU fallback works with
//! DAEMON_INFER_N_GPU_LAYERS=0, so it can run without a GPU.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use daemon_api::{ApiRequest, ApiResponse};
use daemon_common::{DownloadState, ModelEngine, ModelRef, ModelSource, SearchQuery, SearchSort};
use daemon_system_tests::{
    api_call, parse_models_summary, run_gui_models, run_turn, Bins, Daemon, RecordingProxy,
};

const SMOL_REPO: &str = "bartowski/SmolLM2-135M-Instruct-GGUF";

fn daemon_bin() -> Option<PathBuf> {
    std::env::var_os("DAEMON_BIN").map(PathBuf::from)
}
fn gui_bin() -> Option<PathBuf> {
    std::env::var_os("CLIENT_GUI_BIN").map(PathBuf::from)
}

/// The hermetic client-wiring test: every model-track frame the client issues crosses the socket
/// and the client decodes the daemon's reply. Deterministic - no network or model worker needed.
#[test]
fn gui_model_track_wires_through() {
    let Some(gui) = gui_bin() else {
        eprintln!("skipping gui_model_track_wires_through: CLIENT_GUI_BIN unset");
        return;
    };
    if daemon_bin().is_none() {
        eprintln!("skipping gui_model_track_wires_through: DAEMON_BIN unset");
        return;
    }

    let daemon = Daemon::start().expect("daemon becomes ready");
    let proxy = RecordingProxy::start(daemon.socket.clone()).expect("proxy starts");

    let run = run_gui_models(&gui, &proxy.socket, "SmolLM2", SMOL_REPO, 30000).expect("gui runs");
    let summary = parse_models_summary(&run.stdout);
    assert!(
        !summary.is_empty(),
        "no DAEMON_APP_MODELS summary line.\nstdout:\n{}\nstderr:\n{}\ndaemon log:\n{}",
        run.stdout,
        run.stderr,
        daemon.log_contents()
    );

    // ModelCatalog + ModelDownloads always return a list (empty without a manager/registry), so the
    // client must decode them cleanly.
    assert_eq!(
        summary.get("catalog").map(String::as_str),
        Some("ok"),
        "summary: {summary:?}"
    );
    assert_eq!(
        summary.get("downloads").map(String::as_str),
        Some("ok"),
        "summary: {summary:?}"
    );
    // Search / files / download depend on the Hub (network) - but the frame must round-trip either
    // way: a structured ok or a daemon ApiError, never a timeout (which would mean the client never
    // got a reply, i.e. broken wiring).
    for key in ["search", "files", "download"] {
        let got = summary.get(key).map(String::as_str);
        assert!(
            matches!(got, Some("ok") | Some("err")),
            "{key} did not round-trip (got {got:?}); summary: {summary:?}\ndaemon log:\n{}",
            daemon.log_contents()
        );
    }

    // And the frames really crossed the socket (proxy trace), with the correct typed shapes.
    let frames = proxy.requests();
    let has = |pred: fn(&ApiRequest) -> bool| frames.iter().any(pred);
    assert!(
        has(|r| matches!(r, ApiRequest::ModelCatalog)),
        "no ModelCatalog: {frames:?}"
    );
    assert!(
        has(|r| matches!(r, ApiRequest::ModelDownloads)),
        "no ModelDownloads: {frames:?}"
    );
    assert!(
        has(|r| matches!(r, ApiRequest::ModelSearch { .. })),
        "no ModelSearch: {frames:?}"
    );
    assert!(
        has(|r| matches!(r, ApiRequest::ModelFiles { .. })),
        "no ModelFiles: {frames:?}"
    );
    assert!(
        has(|r| matches!(r, ApiRequest::ModelDownload { .. })),
        "no ModelDownload: {frames:?}"
    );
}

/// Opt-in real local-inference e2e: SmolLM2-135M over llama.cpp (Vulkan or CPU fallback). Gated on
/// DAEMON_VULKAN_E2E=1 + a built worker in DAEMON_INFER_BIN. Drives the full pipeline directly over
/// the socket (the same frames the GUI quant picker issues) and asserts a real local completion.
#[test]
fn local_models_smollm2_end_to_end() {
    if std::env::var("DAEMON_VULKAN_E2E").ok().as_deref() != Some("1") {
        eprintln!("skipping local_models_smollm2_end_to_end: set DAEMON_VULKAN_E2E=1 to run");
        return;
    }
    let Some(infer_bin) = std::env::var_os("DAEMON_INFER_BIN") else {
        eprintln!("skipping local_models_smollm2_end_to_end: DAEMON_INFER_BIN unset (build the llama worker)");
        return;
    };
    let bins = match Bins::from_env() {
        Ok(b) => b,
        Err(e) => {
            eprintln!("skipping local_models_smollm2_end_to_end: {e}");
            return;
        }
    };
    // CPU fallback unless the caller asked for GPU layers; the worker selects Vulkan when built with
    // it and n_gpu_layers > 0.
    let gpu_layers = std::env::var("DAEMON_INFER_N_GPU_LAYERS").unwrap_or_else(|_| "0".into());
    let daemon = Daemon::start_with_env(
        &bins,
        &[
            ("DAEMON_MODEL_PROVIDER", "llama".into()),
            ("DAEMON_INFER_BIN", infer_bin.to_string_lossy().into_owned()),
            ("DAEMON_INFER_N_GPU_LAYERS", gpu_layers),
        ],
    )
    .expect("daemon (llama) becomes ready");

    // 1) Search the Hub for the SmolLM2 repo.
    let page = match api_call(
        &daemon.socket,
        &ApiRequest::ModelSearch {
            query: SearchQuery {
                text: "SmolLM2-135M-Instruct".into(),
                engine: ModelEngine::Llama,
                sort: SearchSort::Trending,
                page: 0,
                limit: 25,
            },
        },
    )
    .expect("ModelSearch round-trips")
    {
        ApiResponse::ModelSearch(p) => p,
        ApiResponse::Error(e) => panic!("ModelSearch failed (network?): {e:?}"),
        other => panic!("ModelSearch unexpected: {other:?}"),
    };
    let repo = page
        .results
        .iter()
        .map(|h| h.repo.clone())
        .find(|r| r == SMOL_REPO)
        .or_else(|| page.results.first().map(|h| h.repo.clone()))
        .expect("at least one SmolLM2 repo");
    eprintln!("local-models: using repo {repo}");

    // 2) List its files and pick the smallest quantized GGUF (fast to download + run).
    let files = match api_call(
        &daemon.socket,
        &ApiRequest::ModelFiles {
            repo: repo.clone(),
            revision: None,
            engine: ModelEngine::Llama,
        },
    )
    .expect("ModelFiles round-trips")
    {
        ApiResponse::ModelFiles(f) => f,
        ApiResponse::Error(e) => panic!("ModelFiles failed: {e:?}"),
        other => panic!("ModelFiles unexpected: {other:?}"),
    };
    let pick = files
        .iter()
        .filter(|f| f.quant.is_some() && (!f.is_split || f.is_first_shard))
        .min_by_key(|f| f.size_bytes)
        .expect("a quantized GGUF file");
    eprintln!(
        "local-models: downloading {} ({} bytes)",
        pick.path, pick.size_bytes
    );

    // 3) Download it.
    match api_call(
        &daemon.socket,
        &ApiRequest::ModelDownload {
            model: ModelRef::new(
                ModelEngine::Llama,
                ModelSource::Hf {
                    repo: repo.clone(),
                    file: Some(pick.path.clone()),
                    revision: "main".into(),
                },
            ),
        },
    )
    .expect("ModelDownload round-trips")
    {
        ApiResponse::ModelDownloadStarted(_) => {}
        ApiResponse::Error(e) => panic!("ModelDownload failed: {e:?}"),
        other => panic!("ModelDownload unexpected: {other:?}"),
    }

    // 4) Poll until every job settles; require at least one Completed (5 min budget for the pull).
    let deadline = Instant::now() + Duration::from_secs(300);
    let mut completed = false;
    while Instant::now() < deadline {
        let jobs = match api_call(&daemon.socket, &ApiRequest::ModelDownloads)
            .expect("ModelDownloads round-trips")
        {
            ApiResponse::ModelDownloads(j) => j,
            other => panic!("ModelDownloads unexpected: {other:?}"),
        };
        if jobs
            .iter()
            .any(|j| matches!(j.state, DownloadState::Failed))
        {
            let err = jobs
                .iter()
                .find_map(|j| j.error.clone())
                .unwrap_or_default();
            panic!(
                "download failed: {err}\ndaemon log:\n{}",
                daemon.log_contents()
            );
        }
        if !jobs.is_empty()
            && jobs
                .iter()
                .all(|j| matches!(j.state, DownloadState::Completed))
        {
            completed = true;
            break;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    assert!(
        completed,
        "download did not complete in time\ndaemon log:\n{}",
        daemon.log_contents()
    );

    // 5) The downloaded model is cataloged; activate it as the default local model.
    let installed = match api_call(&daemon.socket, &ApiRequest::ModelCatalog)
        .expect("ModelCatalog round-trips")
    {
        ApiResponse::ModelCatalog(m) => m,
        other => panic!("ModelCatalog unexpected: {other:?}"),
    };
    let model = installed.first().expect("a cataloged model after download");
    eprintln!("local-models: activating {}", model.id);
    match api_call(
        &daemon.socket,
        &ApiRequest::ModelActivate {
            id: model.id.clone(),
            profile: None,
        },
    )
    .expect("ModelActivate round-trips")
    {
        ApiResponse::Ok => {}
        ApiResponse::Error(e) => panic!("ModelActivate failed: {e:?}"),
        other => panic!("ModelActivate unexpected: {other:?}"),
    }

    // 6) Run a real local turn through the activated model.
    let turn = run_turn(
        &daemon.socket,
        "local-smollm2",
        "Reply with exactly one word: pong.",
        Duration::from_secs(180),
    )
    .expect("local turn runs");
    assert!(
        turn.completed || !turn.final_text.trim().is_empty(),
        "expected a real local completion; error: {:?}\ndaemon log:\n{}",
        turn.error,
        daemon.log_contents()
    );
    eprintln!("local-models: SmolLM2 said {:?}", turn.final_text.trim());
}
