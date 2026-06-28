//! daemon-system-tests: the Rust spine for cross-repo end-to-end tests.
//!
//! The client is thin, so the highest-value assertions live at the socket boundary. This harness
//! spawns the real `daemon` binary on an isolated Unix socket, optionally interposes a recording
//! proxy that decodes every length-framed CBOR frame with `daemon-api`'s own [`ApiRequest`] /
//! [`ApiResponse`] types, and drives the real GUI/TUI client binaries against it. Binaries are
//! injected via environment variables so the harness runs against the exact artifacts CI built:
//!
//! - `DAEMON_BIN`        - the `daemon` host binary (required)
//! - `DAEMON_CLI_BIN`    - the `daemon-cli` operator CLI (required; used for readiness)
//! - `CLIENT_GUI_BIN`    - the `daemon-app` GUI binary (optional; GUI scenarios skip without it)
//! - `CLIENT_TUI_BIN`    - the `daemon-tui` TUI binary (optional; TUI scenarios skip without it)

use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use daemon_api::{from_cbor, to_cbor, ApiRequest, ApiResponse, WireC2S, WireS2C};
use tempfile::TempDir;

/// Binary paths injected by the build/CI layer.
pub struct Bins {
    pub daemon: PathBuf,
    pub daemon_cli: PathBuf,
    pub client_gui: Option<PathBuf>,
    pub client_tui: Option<PathBuf>,
}

impl Bins {
    pub fn from_env() -> Result<Bins> {
        let req = |key: &str| -> Result<PathBuf> {
            std::env::var_os(key)
                .map(PathBuf::from)
                .ok_or_else(|| anyhow!("{key} is not set (point it at the built binary)"))
        };
        Ok(Bins {
            daemon: req("DAEMON_BIN")?,
            daemon_cli: req("DAEMON_CLI_BIN")?,
            client_gui: std::env::var_os("CLIENT_GUI_BIN").map(PathBuf::from),
            client_tui: std::env::var_os("CLIENT_TUI_BIN").map(PathBuf::from),
        })
    }
}

/// A running daemon on an isolated socket + state dir. Dropping it tears down the whole process
/// group and removes the temp dir (logs included), so tests are parallel-safe and self-cleaning.
pub struct Daemon {
    child: Child,
    pgid: i32,
    pub socket: PathBuf,
    pub data_dir: PathBuf,
    pub log: PathBuf,
    cli: PathBuf,
    _tmp: TempDir,
}

impl Daemon {
    /// Spawn the daemon and block until `daemon-cli health` reports it ready.
    pub fn start() -> Result<Daemon> {
        let bins = Bins::from_env()?;
        Self::start_with(&bins)
    }

    pub fn start_with(bins: &Bins) -> Result<Daemon> {
        Self::start_with_env(bins, &[])
    }

    /// As [`Daemon::start_with`], but with extra environment for the daemon process. Used by the
    /// opt-in inference e2e to select a real cloud provider (e.g. `DAEMON_MODEL_PROVIDER=genai`,
    /// `DAEMON_MODEL=<id>`, `ANTHROPIC_API_KEY=<key>`).
    pub fn start_with_env(bins: &Bins, extra_env: &[(&str, String)]) -> Result<Daemon> {
        // Keep the root short: a filesystem Unix socket path must fit in sun_path (108 bytes).
        let tmp = tempfile::Builder::new()
            .prefix("dst-")
            .tempdir_in("/tmp")
            .context("creating temp root")?;
        let socket = tmp.path().join("d.sock");
        let data_dir = tmp.path().join("state");
        let home = tmp.path().join("home");
        for dir in [&data_dir, &home] {
            std::fs::create_dir_all(dir)?;
        }
        let log = tmp.path().join("daemon.log");
        let log_file = std::fs::File::create(&log)?;
        let log_err = log_file.try_clone()?;

        let mut cmd = Command::new(&bins.daemon);
        cmd.env("DAEMON_API_SOCKET", &socket)
            .env("DAEMON_DATA_DIR", &data_dir)
            .env("HOME", &home)
            .env("XDG_DATA_HOME", home.join(".local/share"))
            .env("XDG_CONFIG_HOME", home.join(".config"))
            .env("XDG_CACHE_HOME", home.join(".cache"))
            .env("RUST_BACKTRACE", "1")
            .env("RUST_LOG", std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()))
            .stdin(Stdio::null())
            .stdout(Stdio::from(log_file))
            .stderr(Stdio::from(log_err));
        for (k, v) in extra_env {
            cmd.env(k, v);
        }
        // Own session/process group so teardown can reap any workers the daemon spawns.
        unsafe {
            cmd.pre_exec(|| {
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = cmd.spawn().with_context(|| {
            format!("spawning daemon {}", bins.daemon.display())
        })?;
        let pgid = child.id() as i32;

        let daemon = Daemon {
            child,
            pgid,
            socket,
            data_dir,
            log,
            cli: bins.daemon_cli.clone(),
            _tmp: tmp,
        };
        daemon.wait_ready(Duration::from_secs(15))?;
        Ok(daemon)
    }

    /// Poll `daemon-cli --socket <s> health` until it succeeds or the deadline passes.
    pub fn wait_ready(&self, timeout: Duration) -> Result<()> {
        let deadline = Instant::now() + timeout;
        loop {
            let ok = Command::new(&self.cli)
                .arg("--socket")
                .arg(&self.socket)
                .arg("health")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if ok {
                return Ok(());
            }
            if Instant::now() >= deadline {
                bail!(
                    "daemon did not become ready within {:?}; log at {}",
                    timeout,
                    self.log.display()
                );
            }
            thread::sleep(Duration::from_millis(50));
        }
    }

    /// Read the daemon's captured log (for failure diagnostics / artifacts).
    pub fn log_contents(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        unsafe {
            libc::kill(-self.pgid, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            match self.child.try_wait() {
                Ok(Some(_)) => break,
                _ => thread::sleep(Duration::from_millis(20)),
            }
        }
        unsafe {
            libc::kill(-self.pgid, libc::SIGKILL);
        }
        let _ = self.child.wait();
    }
}

/// One decoded protocol frame observed by the proxy.
#[derive(Debug, Clone)]
pub struct Frame {
    /// True for client -> daemon, false for daemon -> client.
    pub from_client: bool,
    /// The decoded request (client -> daemon frames), if it decoded as one.
    pub request: Option<ApiRequest>,
    /// The decoded response (daemon -> client frames), if it decoded as one.
    pub response: Option<ApiResponse>,
    /// Raw payload length (always recorded, even when typed decode fails).
    pub len: usize,
}

/// A recording Unix-socket proxy. Point the client at [`RecordingProxy::socket`]; it forwards to the
/// daemon and records every frame, decoded with daemon-api's own types.
pub struct RecordingProxy {
    pub socket: PathBuf,
    trace: Arc<Mutex<Vec<Frame>>>,
    shutdown: Arc<AtomicBool>,
    accept: Option<JoinHandle<()>>,
    _tmp: TempDir,
}

impl RecordingProxy {
    /// Start a proxy in front of `daemon_socket`.
    pub fn start(daemon_socket: PathBuf) -> Result<RecordingProxy> {
        let tmp = tempfile::Builder::new()
            .prefix("dstp-")
            .tempdir_in("/tmp")
            .context("creating proxy temp root")?;
        let socket = tmp.path().join("p.sock");
        let listener = UnixListener::bind(&socket)
            .with_context(|| format!("binding proxy socket {}", socket.display()))?;
        listener.set_nonblocking(true)?;

        let trace = Arc::new(Mutex::new(Vec::new()));
        let shutdown = Arc::new(AtomicBool::new(false));

        let accept = {
            let trace = Arc::clone(&trace);
            let shutdown = Arc::clone(&shutdown);
            thread::spawn(move || {
                while !shutdown.load(Ordering::Relaxed) {
                    match listener.accept() {
                        Ok((client, _)) => {
                            let upstream = match UnixStream::connect(&daemon_socket) {
                                Ok(s) => s,
                                Err(_) => continue,
                            };
                            client.set_nonblocking(false).ok();
                            spawn_relays(client, upstream, Arc::clone(&trace));
                        }
                        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(10));
                        }
                        Err(_) => break,
                    }
                }
            })
        };

        Ok(RecordingProxy {
            socket,
            trace,
            shutdown,
            accept: Some(accept),
            _tmp: tmp,
        })
    }

    /// A snapshot of the frames recorded so far.
    pub fn frames(&self) -> Vec<Frame> {
        self.trace.lock().unwrap().clone()
    }

    /// All decoded requests observed, in order.
    pub fn requests(&self) -> Vec<ApiRequest> {
        self.frames()
            .into_iter()
            .filter_map(|f| f.request)
            .collect()
    }

    /// All decoded responses observed, in order.
    pub fn responses(&self) -> Vec<ApiResponse> {
        self.frames()
            .into_iter()
            .filter_map(|f| f.response)
            .collect()
    }

    /// Block until a request matching `pred` has been observed, or the deadline passes.
    pub fn wait_for_request<F>(&self, mut pred: F, timeout: Duration) -> Result<ApiRequest>
    where
        F: FnMut(&ApiRequest) -> bool,
    {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(found) = self.requests().into_iter().find(|r| pred(r)) {
                return Ok(found);
            }
            if Instant::now() >= deadline {
                bail!("no matching request within {:?}", timeout);
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for RecordingProxy {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Relaxed);
        // Nudge the accept loop out of its blocking-ish wait by poking the socket.
        let _ = UnixStream::connect(&self.socket);
        if let Some(handle) = self.accept.take() {
            let _ = handle.join();
        }
    }
}

fn spawn_relays(client: UnixStream, upstream: UnixStream, trace: Arc<Mutex<Vec<Frame>>>) {
    let c2d_from = client.try_clone().expect("clone client");
    let c2d_to = upstream.try_clone().expect("clone upstream");
    let t1 = Arc::clone(&trace);
    thread::spawn(move || {
        relay(c2d_from, c2d_to, true, t1);
    });
    thread::spawn(move || {
        relay(upstream, client, false, trace);
    });
}

/// Decode a client->daemon frame into its `ApiRequest`. Multiplexed clients (wire L0) wrap the
/// request in a `Call`/`Open` envelope; a legacy (bare) frame decodes directly. The envelope tags
/// are disjoint from the request tags, so trying the envelope first never misclassifies a bare one.
fn decode_client_request(payload: &[u8]) -> Option<ApiRequest> {
    if let Ok(frame) = from_cbor::<WireC2S>(payload) {
        return match frame {
            WireC2S::Call { req, .. } | WireC2S::Open { req, .. } => Some(req),
            WireC2S::Hello { .. } | WireC2S::Cancel { .. } => None,
        };
    }
    from_cbor::<ApiRequest>(payload).ok()
}

/// Decode a daemon->client frame into its `ApiResponse` (unwrapping a `Reply`/`Item` envelope, or a
/// legacy bare response).
fn decode_daemon_response(payload: &[u8]) -> Option<ApiResponse> {
    if let Ok(frame) = from_cbor::<WireS2C>(payload) {
        return match frame {
            WireS2C::Reply { res, .. } | WireS2C::Item { res, .. } => Some(res),
            WireS2C::Hello { .. } | WireS2C::End { .. } | WireS2C::Reset { .. } => None,
        };
    }
    from_cbor::<ApiResponse>(payload).ok()
}

/// Read length-framed CBOR from `from`, decode + record, and forward verbatim to `to`.
fn relay(mut from: UnixStream, mut to: UnixStream, from_client: bool, trace: Arc<Mutex<Vec<Frame>>>) {
    loop {
        let mut len_buf = [0u8; 4];
        if from.read_exact(&mut len_buf).is_err() {
            break;
        }
        let len = u32::from_be_bytes(len_buf) as usize;
        let mut payload = vec![0u8; len];
        if from.read_exact(&mut payload).is_err() {
            break;
        }

        let (request, response) = if from_client {
            (decode_client_request(&payload), None)
        } else {
            (None, decode_daemon_response(&payload))
        };
        trace.lock().unwrap().push(Frame {
            from_client,
            request,
            response,
            len,
        });

        if to.write_all(&len_buf).is_err()
            || to.write_all(&payload).is_err()
            || to.flush().is_err()
        {
            break;
        }
    }
    let _ = from.shutdown(Shutdown::Both);
    let _ = to.shutdown(Shutdown::Both);
}

/// Run `daemon-cli --socket <socket> <args...>`, returning success + captured stdout.
pub fn run_cli(cli: &std::path::Path, socket: &std::path::Path, args: &[&str]) -> Result<(bool, String)> {
    let out = Command::new(cli)
        .arg("--socket")
        .arg(socket)
        .args(args)
        .output()
        .with_context(|| format!("running {} {:?}", cli.display(), args))?;
    Ok((out.status.success(), String::from_utf8_lossy(&out.stdout).into_owned()))
}

/// The captured result of a one-shot client run (offscreen GUI render / TUI frame dump).
#[derive(Debug)]
pub struct ClientRun {
    pub success: bool,
    pub stdout: String,
    pub stderr: String,
    /// The client's isolated HOME, so a test can read back the persisted QSettings after the run.
    pub home: PathBuf,
    /// Kept alive so the isolated HOME/XDG dirs (and any spawned-daemon socket dir) outlive the run.
    _tmps: Vec<TempDir>,
}

impl ClientRun {
    /// Path to the client's persisted QSettings file after the run.
    pub fn config_path(&self) -> PathBuf {
        self.home.join(".config/daemon-app/daemon-app.conf")
    }

    /// Whether the client persisted `setupComplete=true` (CON-1: connection success persists setup).
    pub fn persisted_setup_complete(&self) -> bool {
        std::fs::read_to_string(self.config_path())
            .map(|s| s.lines().any(|l| l.trim() == "setupComplete=true"))
            .unwrap_or(false)
    }
}

/// QSettings body for a returning user: setup complete, auto-connects in local mode.
const CONF_SETUP_COMPLETE: &str = "[app]\nsetupComplete=true\n\n[conn]\nmode=local\n";
/// QSettings body for a fresh first-run user who will drive the onboarding connect. Managed local
/// daemon is on; shutdown-on-exit is on so a daemon the client spawns is reaped when it exits
/// (no leaked process in the spawn scenario).
const CONF_FRESH_MANAGED: &str =
    "[app]\nsetupComplete=false\n\n[conn]\nmode=local\nmanagedLocalDaemon=true\nmanagedDaemonShutdownOnExit=true\n";

fn isolated_client_command_with_conf(
    bin: &std::path::Path,
    socket: &std::path::Path,
    conf: &str,
) -> Result<(Command, TempDir, PathBuf)> {
    let tmp = tempfile::Builder::new()
        .prefix("dstc-")
        .tempdir_in("/tmp")
        .context("creating client temp root")?;
    let home = tmp.path().join("home");
    std::fs::create_dir_all(&home)?;
    // Seed the shared QSettings ("daemon-app"/"daemon-app"); the socket itself comes from
    // DAEMON_APP_SOCKET below (which wins over the persisted target).
    let cfg_dir = home.join(".config/daemon-app");
    std::fs::create_dir_all(&cfg_dir)?;
    std::fs::write(cfg_dir.join("daemon-app.conf"), conf)?;
    let mut cmd = Command::new(bin);
    cmd.env("DAEMON_APP_SERVICE_MODE", "daemon")
        .env("DAEMON_APP_SOCKET", socket)
        .env("HOME", &home)
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("XDG_DATA_HOME", home.join(".local/share"))
        .env("XDG_CACHE_HOME", home.join(".cache"))
        .env("LANG", "C.UTF-8");
    Ok((cmd, tmp, home))
}

fn isolated_client_command(
    bin: &std::path::Path,
    socket: &std::path::Path,
) -> Result<(Command, TempDir, PathBuf)> {
    isolated_client_command_with_conf(bin, socket, CONF_SETUP_COMPLETE)
}

fn run_with_timeout(
    mut cmd: Command,
    tmps: Vec<TempDir>,
    home: PathBuf,
    timeout: Duration,
) -> Result<ClientRun> {
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().context("spawning client")?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait()? {
            Some(_) => break,
            None if Instant::now() >= deadline => {
                let _ = child.kill();
                break;
            }
            None => thread::sleep(Duration::from_millis(20)),
        }
    }
    let out = child.wait_with_output()?;
    Ok(ClientRun {
        success: out.status.success(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        home,
        _tmps: tmps,
    })
}

/// Drive the GUI (`daemon-app`) in its offscreen render-shot harness against `socket`. Renders the
/// requested page to PNGs in a temp dir and exits; assert on the protocol trace the proxy captured.
pub fn run_gui_offscreen(bin: &std::path::Path, socket: &std::path::Path, page: Option<&str>) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command(bin, socket)?;
    let shots = tmp.path().join("shots");
    std::fs::create_dir_all(&shots)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_RENDER_SHOTS", &shots);
    if let Some(page) = page {
        cmd.env("DAEMON_APP_RENDER_PAGE", page);
    }
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(30))
}

/// Drive the GUI headless until its daemon-mode auto-connect reaches "ready" (a real Health
/// round-trip) or times out, then exit. Prints `DAEMON_APP_READY ok|timeout` on stdout. Lets a
/// scenario hard-assert connectivity instead of racing the async connect.
pub fn run_gui_wait_ready(bin: &std::path::Path, socket: &std::path::Path, timeout_ms: u32) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command(bin, socket)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string());
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(30))
}

/// Drive the TUI headless until its daemon-mode auto-connect reaches "ready" or times out (printing
/// `DAEMON_APP_READY ok|timeout`), then dump one frame. Same hard-assert contract as the GUI.
pub fn run_tui_wait_ready(bin: &std::path::Path, socket: &std::path::Path, dims: (u16, u16), timeout_ms: u32) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command(bin, socket)?;
    cmd.env("DAEMON_TUI_OFFSCREEN", format!("{}x{}", dims.0, dims.1))
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string());
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(30))
}

/// Drive the TUI (`daemon-tui`) in its offscreen frame-dump harness against `socket`: feed an
/// optional key sequence / typed text, settle, and dump one rendered frame to stdout.
pub fn run_tui_offscreen(
    bin: &std::path::Path,
    socket: &std::path::Path,
    dims: (u16, u16),
    keys: Option<&str>,
    typ: Option<&str>,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command(bin, socket)?;
    cmd.env("DAEMON_TUI_OFFSCREEN", format!("{}x{}", dims.0, dims.1));
    if let Some(keys) = keys {
        cmd.env("DAEMON_TUI_KEYS", keys);
    }
    if let Some(typ) = typ {
        cmd.env("DAEMON_TUI_TYPE", typ);
    }
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(30))
}

/// Create a short-pathed temp dir + socket path for a client-spawned daemon (must fit sun_path).
fn spawn_socket_dir() -> Result<(TempDir, PathBuf)> {
    let dir = tempfile::Builder::new()
        .prefix("dsts-")
        .tempdir_in("/tmp")
        .context("creating spawn socket temp root")?;
    let socket = dir.path().join("d.sock");
    Ok((dir, socket))
}

/// First-run, managed-spawn (CON-1b): no daemon is pre-started. Run the GUI fresh (setupComplete
/// false), point DAEMON_BIN at the host binary, and drive the onboarding "Local" connect headlessly
/// (wait-ready). The client must discover + spawn a daemon, reach a healthy `Health` (sentinel
/// `DAEMON_APP_READY ok`), and persist setupComplete. The spawned daemon stops on exit (no leak).
pub fn run_gui_first_run_spawns_daemon(
    gui: &std::path::Path,
    daemon_bin: &std::path::Path,
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (sock_tmp, socket) = spawn_socket_dir()?;
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(gui, &socket, CONF_FRESH_MANAGED)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_BIN", daemon_bin);
    run_with_timeout(cmd, vec![tmp, sock_tmp], home, Duration::from_secs(30))
}

/// First-run, managed-spawn for the TUI. Same contract as the GUI variant.
pub fn run_tui_first_run_spawns_daemon(
    tui: &std::path::Path,
    daemon_bin: &std::path::Path,
    dims: (u16, u16),
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (sock_tmp, socket) = spawn_socket_dir()?;
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(tui, &socket, CONF_FRESH_MANAGED)?;
    cmd.env("DAEMON_TUI_OFFSCREEN", format!("{}x{}", dims.0, dims.1))
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_BIN", daemon_bin);
    run_with_timeout(cmd, vec![tmp, sock_tmp], home, Duration::from_secs(30))
}

/// First-run, attach (probe-first): a daemon is ALREADY listening on `socket` (the caller pre-starts
/// one, typically behind a RecordingProxy). The client runs fresh with managed local daemon ON but
/// must reuse the running daemon rather than spawn a second. `DAEMON_BIN` is removed from the child
/// env and no binary is on PATH, so any (incorrect) spawn attempt would fail discovery and leave the
/// client offline - making a passing ready+Health assertion proof that probe-first attached.
pub fn run_gui_first_run_attaches(
    gui: &std::path::Path,
    socket: &std::path::Path,
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(gui, socket, CONF_FRESH_MANAGED)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env_remove("DAEMON_BIN");
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(30))
}

/// Drive the GUI through the full headless first-run onboarding (CON-4/6/7): connect to `socket`
/// (a pre-started daemon, typically behind a RecordingProxy), add the provider `key`, pick the first
/// discovered model, and finish. Asserts via the proxy that the credential/model wire ops crossed,
/// and via the persisted config that setup completed. `DAEMON_BIN` is removed so it attaches.
pub fn run_gui_onboard(
    gui: &std::path::Path,
    socket: &std::path::Path,
    provider: &str,
    key: &str,
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(gui, socket, CONF_FRESH_MANAGED)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_APP_ONBOARD_KEY", key)
        .env("DAEMON_APP_ONBOARD_PROVIDER", provider)
        .env_remove("DAEMON_BIN");
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(45))
}

/// TUI variant of [`run_gui_onboard`].
pub fn run_tui_onboard(
    tui: &std::path::Path,
    socket: &std::path::Path,
    provider: &str,
    key: &str,
    dims: (u16, u16),
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(tui, socket, CONF_FRESH_MANAGED)?;
    cmd.env("DAEMON_TUI_OFFSCREEN", format!("{}x{}", dims.0, dims.1))
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_APP_ONBOARD_KEY", key)
        .env("DAEMON_APP_ONBOARD_PROVIDER", provider)
        .env_remove("DAEMON_BIN");
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(45))
}

/// Drive the GUI through one real headless turn (CHA-1 / CHA-2): connect to `socket` (a pre-started
/// daemon, typically behind a RecordingProxy), Submit{StartTurn} + Subscribe the stream, and print
/// `DAEMON_APP_ANSWER <text>`. Asserts (at the proxy) that Submit + Subscribe crossed and (via
/// stdout) that the client assembled streamed assistant text. `DAEMON_BIN` is removed so it attaches.
pub fn run_gui_chat(
    gui: &std::path::Path,
    socket: &std::path::Path,
    prompt: &str,
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(gui, socket, CONF_FRESH_MANAGED)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_APP_CHAT_PROMPT", prompt)
        .env_remove("DAEMON_BIN");
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(60))
}

/// Drive the GUI's headless profile hook (PRO-2/3): create profile `create_id` via the store
/// (ProfileCreate) and, when `model`/`prompt` are non-empty, edit it (ProfileUpdate), against a
/// pre-started daemon. Asserts (via the proxy) that the create/update wire ops cross. Attaches.
pub fn run_gui_profile(
    gui: &std::path::Path,
    socket: &std::path::Path,
    create_id: &str,
    model: &str,
    prompt: &str,
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(gui, socket, CONF_FRESH_MANAGED)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_APP_PROFILE_CREATE", create_id)
        .env("DAEMON_APP_PROFILE_MODEL", model)
        .env("DAEMON_APP_PROFILE_PROMPT", prompt)
        .env_remove("DAEMON_BIN");
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(45))
}

/// As [`run_gui_chat`] but binds the turn to a specific profile (PRO-5): the client sends
/// `Submit{ profile: Some(<profile>) }`, so the new session runs under that agent.
pub fn run_gui_chat_as_profile(
    gui: &std::path::Path,
    socket: &std::path::Path,
    prompt: &str,
    profile: &str,
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(gui, socket, CONF_FRESH_MANAGED)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_APP_CHAT_PROMPT", prompt)
        .env("DAEMON_APP_CHAT_PROFILE", profile)
        .env_remove("DAEMON_BIN");
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(60))
}

/// Drive the GUI's headless HITL hook (CHA-4 / CHA-5): connect, run one turn that parks on a host
/// gate (the daemon's scripted provider tool call), and auto-resolve it per `decision`
/// ("approve"|"deny"|"choice"|"input:<text>"). Prints `DAEMON_APP_ANSWER <text>`. Asserts (via the
/// proxy) that Submit + Respond cross. Attaches to the pre-started daemon.
pub fn run_gui_hitl(
    gui: &std::path::Path,
    socket: &std::path::Path,
    prompt: &str,
    decision: &str,
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(gui, socket, CONF_FRESH_MANAGED)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_APP_HITL_PROMPT", prompt)
        .env("DAEMON_APP_HITL_DECISION", decision)
        .env_remove("DAEMON_BIN");
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(90))
}

/// Drive the GUI's headless slash-command hook (CHA-7): connect, CommandList, and (when `invoke` is
/// non-empty) CommandInvoke. Prints `DAEMON_APP_COMMANDS <names-or-output>`.
pub fn run_gui_command_list(
    gui: &std::path::Path,
    socket: &std::path::Path,
    invoke: &str,
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(gui, socket, CONF_FRESH_MANAGED)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_APP_COMMAND_LIST", "1")
        .env("DAEMON_APP_COMMAND_INVOKE", invoke)
        .env_remove("DAEMON_BIN");
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(60))
}

/// Drive the GUI's headless session-search hook (CHA-8): connect, SessionSearch `query`. Prints
/// `DAEMON_APP_SEARCH <hit-session-ids>`.
pub fn run_gui_search(
    gui: &std::path::Path,
    socket: &std::path::Path,
    query: &str,
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(gui, socket, CONF_FRESH_MANAGED)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_APP_SESSION_SEARCH", query)
        .env_remove("DAEMON_BIN");
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(60))
}

/// Extract a `<prefix> <text>` line a headless run prints (e.g. `DAEMON_APP_COMMANDS ` /
/// `DAEMON_APP_SEARCH `), or None if absent.
pub fn parse_prefixed(stdout: &str, prefix: &str) -> Option<String> {
    stdout
        .lines()
        .find_map(|l| l.strip_prefix(prefix).map(|s| s.to_string()))
}

/// TUI variant of [`run_gui_chat`].
pub fn run_tui_chat(
    tui: &std::path::Path,
    socket: &std::path::Path,
    prompt: &str,
    dims: (u16, u16),
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(tui, socket, CONF_FRESH_MANAGED)?;
    cmd.env("DAEMON_TUI_OFFSCREEN", format!("{}x{}", dims.0, dims.1))
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_APP_CHAT_PROMPT", prompt)
        .env_remove("DAEMON_BIN");
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(60))
}

/// Extract the `DAEMON_APP_ANSWER <text>` line a headless chat run prints (the assembled assistant
/// text), or None if absent.
pub fn parse_chat_answer(stdout: &str) -> Option<String> {
    stdout
        .lines()
        .find_map(|l| l.strip_prefix("DAEMON_APP_ANSWER ").map(|s| s.to_string()))
}

/// Drive the GUI's headless model-track probe (Phase 2): exercise ModelCatalog / ModelDownloads /
/// ModelSearch / ModelFiles / ModelDownload through the real ModelRepository against a pre-started
/// daemon, printing `DAEMON_APP_MODELS catalog=.. downloads=.. search=.. files=.. download=..`
/// (each ok|err|timeout). Asserts (via the proxy) the model frames cross + (via stdout) the client
/// decoded a structured response for each. `DAEMON_BIN` removed so it attaches.
pub fn run_gui_models(
    gui: &std::path::Path,
    socket: &std::path::Path,
    query: &str,
    repo: &str,
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(gui, socket, CONF_FRESH_MANAGED)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_APP_MODELS_PROBE", query)
        .env("DAEMON_APP_MODELS_REPO", repo)
        .env_remove("DAEMON_BIN");
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(60))
}

/// Drive the GUI's headless filesystem probe (Phase 4 fs seam): connect, then exercise the
/// daemon-backed IFsService over the wire (listRoots -> open -> write a probe file -> read it back)
/// against a pre-started daemon, printing `DAEMON_APP_FS roots=.. root=.. list=.. write=ok read=ok`.
/// Asserts (via the proxy) the Fs frames cross + (via stdout) the round-trip succeeded against the
/// real WorkspaceFs. `DAEMON_BIN` removed so it attaches to the running daemon.
pub fn run_gui_fs(
    gui: &std::path::Path,
    socket: &std::path::Path,
    timeout_ms: u32,
) -> Result<ClientRun> {
    let (mut cmd, tmp, home) = isolated_client_command_with_conf(gui, socket, CONF_FRESH_MANAGED)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string())
        .env("DAEMON_APP_FS_PROBE", "1")
        .env_remove("DAEMON_BIN");
    run_with_timeout(cmd, vec![tmp], home, Duration::from_secs(60))
}

/// Parse the `DAEMON_APP_FS <summary>` line into (key -> value) pairs, e.g.
/// {"roots":"1", "write":"ok", "read":"ok", ...}. Empty if the line is absent.
pub fn parse_fs_summary(stdout: &str) -> std::collections::HashMap<String, String> {
    stdout
        .lines()
        .find_map(|l| l.strip_prefix("DAEMON_APP_FS "))
        .map(|s| {
            s.split_whitespace()
                .filter_map(|kv| kv.split_once('='))
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

/// Parse the `DAEMON_APP_MODELS <summary>` line into (key -> outcome) pairs, e.g.
/// {"catalog":"ok", "search":"err", ...}. Empty if the line is absent.
pub fn parse_models_summary(stdout: &str) -> std::collections::HashMap<String, String> {
    stdout
        .lines()
        .find_map(|l| l.strip_prefix("DAEMON_APP_MODELS "))
        .map(|s| {
            s.split_whitespace()
                .filter_map(|kv| kv.split_once('='))
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

/// One framed `ApiRequest` -> `ApiResponse` round-trip over `socket` (length-prefixed CBOR, the same
/// frame shape the client + proxy use). Each call is its own short-lived connection; session state
/// lives in the daemon, so submit-then-poll across two calls is fine.
pub fn api_call(socket: &std::path::Path, request: &ApiRequest) -> Result<ApiResponse> {
    let mut stream = UnixStream::connect(socket)
        .with_context(|| format!("connecting api socket {}", socket.display()))?;
    let payload = to_cbor(request);
    stream.write_all(&(payload.len() as u32).to_be_bytes())?;
    stream.write_all(&payload)?;
    stream.flush()?;
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf) as usize;
    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf)?;
    from_cbor::<ApiResponse>(&buf).map_err(|e| anyhow!("decoding ApiResponse: {e}"))
}

/// The outcome of driving one real agent turn (the opt-in inference e2e).
#[derive(Debug, Default)]
pub struct TurnResult {
    /// True iff the turn ended with `EndReason::Completed` (a real, non-error answer).
    pub completed: bool,
    /// The aggregated assistant text (final summary text, or accumulated deltas).
    pub final_text: String,
    /// A turn-level error string, if the engine emitted `AgentEvent::Error`.
    pub error: Option<String>,
}

/// Drive one real turn over `socket`: `Submit { StartTurn }` then `Poll` until `TurnFinished`
/// (or `timeout`). Returns whether it completed + the final text. Proves a credential actually
/// provisions inference end-to-end (used by the opt-in Anthropic e2e).
pub fn run_turn(
    socket: &std::path::Path,
    session: &str,
    text: &str,
    timeout: Duration,
) -> Result<TurnResult> {
    run_turn_as_profile(socket, session, text, None, timeout)
}

/// As [`run_turn`] but binds the turn to `profile` (PRO-6 credential isolation): the engine acquires
/// the credential for that profile, so a turn under a profile with no stored key fails ("no
/// provider", CON-8).
pub fn run_turn_as_profile(
    socket: &std::path::Path,
    session: &str,
    text: &str,
    profile: Option<&str>,
    timeout: Duration,
) -> Result<TurnResult> {
    use daemon_common::{ProfileRef, ReqId, SessionId};
    use daemon_protocol::{AgentCommand, AgentEvent, EndReason, Outbound, UserMsg};

    let submit = ApiRequest::Submit {
        session: SessionId::new(session),
        command: AgentCommand::StartTurn {
            input: UserMsg::new(text),
            request_id: ReqId(1),
        },
        origin: None,
        profile: profile.map(ProfileRef::new),
    };
    match api_call(socket, &submit)? {
        ApiResponse::Ok => {}
        ApiResponse::Error(e) => bail!("Submit returned an error: {e:?}"),
        other => bail!("Submit returned unexpected response: {other:?}"),
    }

    let mut result = TurnResult::default();
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let drained = match api_call(
            socket,
            &ApiRequest::Poll {
                session: SessionId::new(session),
                max: 0,
            },
        )? {
            ApiResponse::Drained(items) => items,
            ApiResponse::Error(e) => bail!("Poll returned an error: {e:?}"),
            other => bail!("Poll returned unexpected response: {other:?}"),
        };
        for item in drained {
            if let Outbound::Event(event) = item {
                match event {
                    AgentEvent::TextDelta { text, .. } => result.final_text.push_str(&text),
                    AgentEvent::Error { failure, .. } => result.error = Some(failure),
                    AgentEvent::TurnFinished { summary, .. } => {
                        result.completed = matches!(summary.end_reason, EndReason::Completed);
                        if let Some(t) = summary.final_text {
                            if !t.is_empty() {
                                result.final_text = t;
                            }
                        }
                        return Ok(result);
                    }
                    _ => {}
                }
            }
        }
        thread::sleep(Duration::from_millis(200));
    }
    Ok(result)
}
