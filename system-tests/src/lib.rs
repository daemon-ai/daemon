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
use daemon_api::{from_cbor, ApiRequest, ApiResponse};
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
            (from_cbor::<ApiRequest>(&payload).ok(), None)
        } else {
            (None, from_cbor::<ApiResponse>(&payload).ok())
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
    /// Kept alive so the isolated HOME/XDG dirs outlive the run for diagnostics.
    _tmp: TempDir,
}

fn isolated_client_command(bin: &std::path::Path, socket: &std::path::Path) -> Result<(Command, TempDir)> {
    let tmp = tempfile::Builder::new()
        .prefix("dstc-")
        .tempdir_in("/tmp")
        .context("creating client temp root")?;
    let home = tmp.path().join("home");
    std::fs::create_dir_all(&home)?;
    // Seed the shared QSettings ("daemon-app"/"daemon-app") so the client treats setup as complete
    // and auto-connects in local mode; the socket itself comes from DAEMON_APP_SOCKET below.
    let cfg_dir = home.join(".config/daemon-app");
    std::fs::create_dir_all(&cfg_dir)?;
    std::fs::write(
        cfg_dir.join("daemon-app.conf"),
        "[app]\nsetupComplete=true\n\n[conn]\nmode=local\n",
    )?;
    let mut cmd = Command::new(bin);
    cmd.env("DAEMON_APP_SERVICE_MODE", "daemon")
        .env("DAEMON_APP_SOCKET", socket)
        .env("HOME", &home)
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("XDG_DATA_HOME", home.join(".local/share"))
        .env("XDG_CACHE_HOME", home.join(".cache"))
        .env("LANG", "C.UTF-8");
    Ok((cmd, tmp))
}

fn run_with_timeout(mut cmd: Command, tmp: TempDir, timeout: Duration) -> Result<ClientRun> {
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
        _tmp: tmp,
    })
}

/// Drive the GUI (`daemon-app`) in its offscreen render-shot harness against `socket`. Renders the
/// requested page to PNGs in a temp dir and exits; assert on the protocol trace the proxy captured.
pub fn run_gui_offscreen(bin: &std::path::Path, socket: &std::path::Path, page: Option<&str>) -> Result<ClientRun> {
    let (mut cmd, tmp) = isolated_client_command(bin, socket)?;
    let shots = tmp.path().join("shots");
    std::fs::create_dir_all(&shots)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_RENDER_SHOTS", &shots);
    if let Some(page) = page {
        cmd.env("DAEMON_APP_RENDER_PAGE", page);
    }
    run_with_timeout(cmd, tmp, Duration::from_secs(30))
}

/// Drive the GUI headless until its daemon-mode auto-connect reaches "ready" (a real Health
/// round-trip) or times out, then exit. Prints `DAEMON_APP_READY ok|timeout` on stdout. Lets a
/// scenario hard-assert connectivity instead of racing the async connect.
pub fn run_gui_wait_ready(bin: &std::path::Path, socket: &std::path::Path, timeout_ms: u32) -> Result<ClientRun> {
    let (mut cmd, tmp) = isolated_client_command(bin, socket)?;
    cmd.env("QT_QPA_PLATFORM", "offscreen")
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string());
    run_with_timeout(cmd, tmp, Duration::from_secs(30))
}

/// Drive the TUI headless until its daemon-mode auto-connect reaches "ready" or times out (printing
/// `DAEMON_APP_READY ok|timeout`), then dump one frame. Same hard-assert contract as the GUI.
pub fn run_tui_wait_ready(bin: &std::path::Path, socket: &std::path::Path, dims: (u16, u16), timeout_ms: u32) -> Result<ClientRun> {
    let (mut cmd, tmp) = isolated_client_command(bin, socket)?;
    cmd.env("DAEMON_TUI_OFFSCREEN", format!("{}x{}", dims.0, dims.1))
        .env("DAEMON_APP_WAIT_READY", timeout_ms.to_string());
    run_with_timeout(cmd, tmp, Duration::from_secs(30))
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
    let (mut cmd, tmp) = isolated_client_command(bin, socket)?;
    cmd.env("DAEMON_TUI_OFFSCREEN", format!("{}x{}", dims.0, dims.1));
    if let Some(keys) = keys {
        cmd.env("DAEMON_TUI_KEYS", keys);
    }
    if let Some(typ) = typ {
        cmd.env("DAEMON_TUI_TYPE", typ);
    }
    run_with_timeout(cmd, tmp, Duration::from_secs(30))
}
