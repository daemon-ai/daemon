// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Jarrad Hope

//! B7 (EIO-13) — the composed Matrix journey: operator connects a Matrix account, a room is bound
//! to an agent, and an inbound room message round-trips through the agent back into the room.
//!
//! Two scenarios, layered:
//!
//! 1. [`matrix_connect_surface_and_room_binding_wire_through`] — the **hermetic** legs, over the
//!    real socket with no homeserver: the Matrix transport adapter registers + enumerates, the
//!    Matrix SSO auth family is advertised, and a room `Origin` binds to an agent session
//!    (`RoutingBindChat` → `RoutingListChats`). Skips only when `DAEMON_BIN` is unset.
//!
//! 2. [`matrix_live_roundtrip_through_conduit`] — the **live-homeserver** leg (this is the leg the
//!    earlier draft named as harness-limited and left to the crate tests). It boots a real
//!    [Conduit](https://conduit.rs) Matrix homeserver as a Docker container, seeds the durable node
//!    stores so the daemon's Matrix adapter connects a real account to it, and drives a full inbound
//!    → agent → outbound round-trip: a human invites the bot (exercising the Wave-A
//!    `invite_allowlist`), the bot auto-joins, the human posts a message, and the agent's reply is
//!    projected back into the room. Skips cleanly when the container runtime / image is unavailable
//!    (no `docker`, image not present + no network to pull, or the homeserver fails to boot) — it
//!    never fakes a pass, and once the homeserver *is* up the round-trip assertions are real.
//!
//! ## Why the account session is seeded rather than SSO-driven
//!
//! The daemon's operator connect flow is SSO (`daemon matrix login`, `AuthFlowKind::MatrixSso`),
//! which is interactive and needs an SSO/OIDC-capable homeserver — plain Conduit has none. But the
//! adapter restores an account from an opaque credential blob (`daemon_matrix::StoredSession`:
//! `{ homeserver, MatrixSession }`) at bring-up, and `MatrixSession` is just the flattened
//! `{ user_id, device_id, access_token }`. Conduit's `/register` returns exactly those, so we mint a
//! real session with the CS API and seed it into the credential store + a `bound_accounts` profile —
//! the same on-disk state a completed SSO login would leave. This drives the *real* adapter code
//! (sync loop, invite acceptance, inbound gate, outbound projector) against a *real* homeserver.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use daemon_api::{
    ApiRequest, ApiResponse, AuthFlowKind, BoundAccount, ProfileSpec, ProviderSelector,
};
use daemon_protocol::{Origin, OriginScope};
use daemon_system_tests::{api_call, Bins, Daemon};

fn daemon_bin() -> Option<PathBuf> {
    std::env::var_os("DAEMON_BIN").map(PathBuf::from)
}

/// Start a daemon with the Matrix transport + SSO auth family enabled (no accounts, no homeserver).
fn matrix_daemon() -> Option<Daemon> {
    let bins = Bins::from_env().ok()?;
    Daemon::start_with_env(&bins, &[("DAEMON_MATRIX__ENABLED", "true".into())]).ok()
}

#[test]
fn matrix_connect_surface_and_room_binding_wire_through() {
    if daemon_bin().is_none() {
        eprintln!("skipping matrix_connect_surface_and_room_binding: DAEMON_BIN unset");
        return;
    }
    let Some(daemon) = matrix_daemon() else {
        eprintln!("skipping matrix_connect_surface_and_room_binding: daemon did not start");
        return;
    };

    // 1. The Matrix transport adapter is registered + enumerable (the Connect surface's target).
    let adapters = match api_call(&daemon.socket, &ApiRequest::TransportAdapters)
        .expect("TransportAdapters")
    {
        ApiResponse::Adapters(a) => a,
        other => panic!("unexpected TransportAdapters response: {other:?}"),
    };
    assert!(
        adapters.iter().any(|a| a.family == "matrix"),
        "the matrix transport adapter should be registered when enabled; got {:?}\ndaemon log:\n{}",
        adapters.iter().map(|a| &a.family).collect::<Vec<_>>(),
        daemon.log_contents()
    );

    // 2. The Matrix SSO auth family is registered (the AuthBegin/AuthComplete connect flow).
    let providers =
        match api_call(&daemon.socket, &ApiRequest::AuthProviders).expect("AuthProviders") {
            ApiResponse::AuthProviders(p) => p,
            other => panic!("unexpected AuthProviders response: {other:?}"),
        };
    assert!(
        providers
            .iter()
            .any(|p| p.family == "matrix" && p.flow_kind == AuthFlowKind::MatrixSso),
        "the matrix SSO auth family should be advertised when the transport is enabled; got {:?}",
        providers
            .iter()
            .map(|p| (&p.family, p.flow_kind))
            .collect::<Vec<_>>()
    );

    // 3a. Mint the agent session the room will bind to (a profile-bound roster session).
    let session = match api_call(
        &daemon.socket,
        &ApiRequest::SessionCreate {
            session: None,
            profile: None,
        },
    )
    .expect("SessionCreate")
    {
        ApiResponse::SessionCreated { session } => session,
        other => panic!("unexpected SessionCreate response: {other:?}"),
    };

    // 3b. Bind a Matrix room origin to that agent session (the room→agent routing pin).
    let room_origin = Origin::new(
        "matrix/@daemonbot:example.org",
        OriginScope::Group {
            chat: "!ops:example.org".into(),
            thread: None,
        },
    );
    let bind = ApiRequest::RoutingBindChat {
        origin: room_origin.clone(),
        session: session.clone(),
        profile: None,
    };
    assert!(
        matches!(api_call(&daemon.socket, &bind).expect("RoutingBindChat"), ApiResponse::Ok),
        "binding a matrix room to an agent session should be accepted over the local socket\ndaemon log:\n{}",
        daemon.log_contents()
    );

    // 3c. The pin is durable + readable back through the routing surface.
    let routes = match api_call(
        &daemon.socket,
        &ApiRequest::RoutingListChats { after: None },
    )
    .expect("RoutingListChats")
    {
        ApiResponse::ChatRoutes(page) => page,
        other => panic!("unexpected RoutingListChats response: {other:?}"),
    };
    assert!(
        routes
            .items
            .iter()
            .any(|r| r.session == session && r.origin.transport == room_origin.transport),
        "the room→agent pin should be listed; got {:?}",
        routes
            .items
            .iter()
            .map(|r| (&r.origin.transport, &r.session))
            .collect::<Vec<_>>()
    );
}

// ---------------------------------------------------------------------------------------------
// Live-homeserver round-trip (B7): Conduit-backed.
// ---------------------------------------------------------------------------------------------

const CONDUIT_IMAGE: &str = "matrixconduit/matrix-conduit:latest";

/// Run a command, returning `(success, stdout)`; `None` if the binary is missing entirely.
fn run(cmd: &str, args: &[&str], timeout: Duration) -> Option<(bool, String)> {
    let mut child = Command::new(cmd)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                break;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(_) => return None,
        }
    }
    let out = child.wait_with_output().ok()?;
    Some((
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
    ))
}

fn docker_available() -> bool {
    run(
        "docker",
        &["version", "--format", "{{.Server.Version}}"],
        Duration::from_secs(15),
    )
    .map(|(ok, _)| ok)
    .unwrap_or(false)
}

/// Ensure the Conduit image is present locally; try a bounded pull if not. Returns whether usable.
fn ensure_conduit_image() -> bool {
    if run(
        "docker",
        &["image", "inspect", CONDUIT_IMAGE],
        Duration::from_secs(15),
    )
    .map(|(ok, _)| ok)
    .unwrap_or(false)
    {
        return true;
    }
    // Not cached: try to pull (bounded). A blocked/offline environment simply skips the scenario.
    run("docker", &["pull", CONDUIT_IMAGE], Duration::from_secs(240))
        .map(|(ok, _)| ok)
        .unwrap_or(false)
}

/// A running Conduit homeserver container. Dropping it force-removes the container.
struct Conduit {
    name: String,
    base_url: String,
}

impl Conduit {
    /// Boot a fresh Conduit on an ephemeral loopback port; `None` if it does not become ready.
    fn start() -> Option<Conduit> {
        let name = format!("dst-conduit-{}", std::process::id());
        // Best-effort cleanup of a stale container from a previous aborted run.
        let _ = run("docker", &["rm", "-f", &name], Duration::from_secs(20));

        let ok = run(
            "docker",
            &[
                "run",
                "-d",
                "--name",
                &name,
                "-p",
                "127.0.0.1::6167",
                "-e",
                "CONDUIT_CONFIG=",
                "-e",
                "CONDUIT_SERVER_NAME=localhost",
                "-e",
                "CONDUIT_DATABASE_BACKEND=rocksdb",
                "-e",
                "CONDUIT_DATABASE_PATH=/var/lib/matrix-conduit/",
                "-e",
                "CONDUIT_ALLOW_REGISTRATION=true",
                "-e",
                "CONDUIT_ALLOW_FEDERATION=false",
                "-e",
                "CONDUIT_ALLOW_CHECK_FOR_UPDATES=false",
                "-e",
                "CONDUIT_PORT=6167",
                "-e",
                "CONDUIT_ADDRESS=0.0.0.0",
                "-e",
                "CONDUIT_MAX_REQUEST_SIZE=20000000",
                CONDUIT_IMAGE,
            ],
            Duration::from_secs(30),
        )?;
        if !ok.0 {
            eprintln!("conduit: docker run failed: {}", ok.1);
            return None;
        }

        // Discover the ephemeral host port docker assigned to the container's 6167.
        let (pok, port_out) = run(
            "docker",
            &["port", &name, "6167/tcp"],
            Duration::from_secs(15),
        )?;
        if !pok {
            eprintln!("conduit: docker port lookup failed");
            let _ = run("docker", &["rm", "-f", &name], Duration::from_secs(20));
            return None;
        }
        // Output like `127.0.0.1:49153` (possibly a `0.0.0.0:` line too); take the first host:port.
        let Some(hostport) = port_out
            .lines()
            .filter_map(|l| l.trim().rsplit_once(':').map(|(_, p)| p.trim().to_string()))
            .find(|p| p.parse::<u16>().is_ok())
        else {
            let _ = run("docker", &["rm", "-f", &name], Duration::from_secs(20));
            return None;
        };
        let base_url = format!("http://127.0.0.1:{hostport}");

        // Wait for the CS API to answer.
        let deadline = Instant::now() + Duration::from_secs(40);
        let mut ready = false;
        while Instant::now() < deadline {
            if let Some((true, body)) = run(
                "curl",
                &[
                    "-s",
                    "-m",
                    "5",
                    &format!("{base_url}/_matrix/client/versions"),
                ],
                Duration::from_secs(8),
            ) {
                if body.contains("versions") {
                    ready = true;
                    break;
                }
            }
            std::thread::sleep(Duration::from_millis(300));
        }
        if !ready {
            let logs = run("docker", &["logs", &name], Duration::from_secs(15))
                .map(|(_, o)| o)
                .unwrap_or_default();
            eprintln!(
                "conduit: homeserver did not become ready at {base_url}\ncontainer logs:\n{logs}"
            );
            let _ = run("docker", &["rm", "-f", &name], Duration::from_secs(20));
            return None;
        }
        Some(Conduit { name, base_url })
    }
}

impl Drop for Conduit {
    fn drop(&mut self) {
        let _ = run("docker", &["rm", "-f", &self.name], Duration::from_secs(25));
    }
}

/// A registered Conduit account: MXID + access token + device id (the shape `/register` returns).
struct Account {
    user_id: String,
    access_token: String,
    device_id: String,
}

/// `curl` the CS API and parse the JSON body. `token`/`body` are optional (GET vs authed POST/PUT).
fn cs_api(
    base_url: &str,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<&str>,
) -> Option<serde_json::Value> {
    let url = format!("{base_url}{path}");
    let bearer = token.map(|t| format!("Authorization: Bearer {t}"));
    let mut args: Vec<&str> = vec![
        "-s",
        "-m",
        "20",
        "-X",
        method,
        "-H",
        "Content-Type: application/json",
    ];
    if let Some(b) = &bearer {
        args.push("-H");
        args.push(b);
    }
    if let Some(b) = body {
        args.push("-d");
        args.push(b);
    }
    args.push(&url);
    let (_, out) = run("curl", &args, Duration::from_secs(25))?;
    serde_json::from_str(&out).ok()
}

/// Register `username` and return its account material; `None` on any failure.
fn register(base_url: &str, username: &str, device: &str) -> Option<Account> {
    let body = serde_json::json!({
        "username": username,
        "password": "roundtrip-pass-12345", // gitleaks:allow — throwaway pw for an ephemeral Conduit test container, not a secret
        "auth": { "type": "m.login.dummy" },
        "device_id": device,
        "initial_device_display_name": username,
    })
    .to_string();
    let v = cs_api(
        base_url,
        "POST",
        "/_matrix/client/v3/register",
        None,
        Some(&body),
    )?;
    Some(Account {
        user_id: v.get("user_id")?.as_str()?.to_string(),
        access_token: v.get("access_token")?.as_str()?.to_string(),
        device_id: v
            .get("device_id")
            .and_then(|d| d.as_str())
            .unwrap_or(device)
            .to_string(),
    })
}

/// Seed the durable node stores so the Matrix adapter restores `bot` at bring-up and binds it to a
/// mock-provider agent profile (the same on-disk shape a completed SSO login + profile edit leaves).
fn seed_matrix_account(data_dir: &Path, bot: &Account, homeserver: &str) -> anyhow::Result<()> {
    let cred_ref = "matrix-bot";
    let transport_instance = format!("matrix/{}", bot.user_id);

    // The bound-account profile (mock provider, so the agent turn produces a deterministic reply).
    let spec = ProfileSpec::new("agent", ProviderSelector::Mock, "mock-model")
        .with_bound_accounts(vec![BoundAccount::new(transport_instance, cred_ref)]);
    let profiles_dir = data_dir.join("profiles");
    std::fs::create_dir_all(&profiles_dir)?;
    std::fs::write(
        profiles_dir.join("agent.json"),
        serde_json::to_vec_pretty(&spec)?,
    )?;
    std::fs::write(profiles_dir.join("active"), b"agent")?;

    // The credential-store blob: `daemon_matrix::StoredSession { homeserver, MatrixSession }`, where
    // MatrixSession serializes flat as `{ user_id, device_id, access_token }`. The store is a JSON
    // `{ credential_ref: opaque_blob_string }` map (see FileCredentialStore).
    let stored_session = serde_json::json!({
        "homeserver": homeserver,
        "session": {
            "user_id": bot.user_id,
            "device_id": bot.device_id,
            "access_token": bot.access_token,
        }
    })
    .to_string();
    let mut creds = serde_json::Map::new();
    creds.insert(
        cred_ref.to_string(),
        serde_json::Value::String(stored_session),
    );
    std::fs::write(
        data_dir.join("credentials.json"),
        serde_json::to_vec_pretty(&serde_json::Value::Object(creds))?,
    )?;
    Ok(())
}

/// Poll `pred` every 500ms until it returns true or `timeout` elapses.
fn poll_until(timeout: Duration, mut pred: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if pred() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

#[test]
fn matrix_live_roundtrip_through_conduit() {
    if daemon_bin().is_none() {
        eprintln!("skipping matrix_live_roundtrip: DAEMON_BIN unset");
        return;
    }
    if !docker_available() {
        eprintln!("skipping matrix_live_roundtrip: no working docker runtime");
        return;
    }
    if !ensure_conduit_image() {
        eprintln!(
            "skipping matrix_live_roundtrip: conduit image unavailable (not cached, pull failed)"
        );
        return;
    }
    let Some(conduit) = Conduit::start() else {
        eprintln!("skipping matrix_live_roundtrip: conduit homeserver did not boot");
        return;
    };
    let base = conduit.base_url.clone();

    // The bot the daemon speaks as, and the human who invites it + chats.
    let Some(bot) = register(&base, "daemonbot", "DAEMONDEV") else {
        eprintln!("skipping matrix_live_roundtrip: bot registration failed");
        return;
    };
    let Some(human) = register(&base, "human", "HUMANDEV") else {
        eprintln!("skipping matrix_live_roundtrip: human registration failed");
        return;
    };

    // A node-config TOML: durable stores (so the seeded profile/credential files are read), the
    // Matrix transport on, the invite allowlist scoped to the human (Wave-A: only their invite is
    // auto-accepted), and a route with mention-gating off so any human message drives a turn.
    let cfg_tmp = tempfile::Builder::new()
        .prefix("dst-mxcfg-")
        .tempdir()
        .expect("config tempdir");
    let cfg_path = cfg_tmp.path().join("node.toml");
    let cfg_toml = format!(
        "store = \"sqlite\"\n\n[matrix]\nenabled = true\nauto_accept_invites = true\ninvite_allowlist = [\"{}\"]\n\n[[matrix.route]]\nmention_gating = false\n",
        human.user_id
    );
    std::fs::write(&cfg_path, cfg_toml).expect("write node config");

    let bins = Bins::from_env().expect("bins");
    let bot_for_seed = Account {
        user_id: bot.user_id.clone(),
        access_token: bot.access_token.clone(),
        device_id: bot.device_id.clone(),
    };
    let homeserver = base.clone();
    let daemon = Daemon::start_with_env_seeded(
        &bins,
        &[("DAEMON_CONFIG", cfg_path.to_string_lossy().into_owned())],
        move |data_dir| seed_matrix_account(data_dir, &bot_for_seed, &homeserver),
    );
    let daemon = match daemon {
        Ok(d) => d,
        Err(e) => {
            eprintln!("skipping matrix_live_roundtrip: daemon did not start: {e:#}");
            return;
        }
    };

    // Precondition: the daemon must actually bring the account up against the live homeserver.
    // (If restore/sync failed, the log says so and there is no point asserting a round-trip.)
    let brought_up = poll_until(Duration::from_secs(45), || {
        daemon.log_contents().contains("matrix: account brought up")
    });
    assert!(
        brought_up,
        "the seeded matrix account should connect to the live conduit homeserver\ndaemon log:\n{}",
        daemon.log_contents()
    );

    // The human creates a room and invites the bot in one shot.
    let create_body = serde_json::json!({
        "name": "roundtrip",
        "preset": "private_chat",
        "invite": [bot.user_id],
    })
    .to_string();
    let room = cs_api(
        &base,
        "POST",
        "/_matrix/client/v3/createRoom",
        Some(&human.access_token),
        Some(&create_body),
    )
    .and_then(|v| v.get("room_id").and_then(|r| r.as_str()).map(String::from))
    .expect("human creates a room + invites the bot");

    // The bot auto-joins (invite acceptance is allowlist-gated to the human — Wave A).
    let joined = poll_until(Duration::from_secs(45), || {
        cs_api(
            &base,
            "GET",
            &format!("/_matrix/client/v3/rooms/{room}/joined_members"),
            Some(&human.access_token),
            None,
        )
        .and_then(|v| v.get("joined").cloned())
        .map(|j| j.get(&bot.user_id).is_some())
        .unwrap_or(false)
    });
    assert!(
        joined,
        "the bot should auto-accept the allowlisted human's invite and join the room\ndaemon log:\n{}",
        daemon.log_contents()
    );

    // The human addresses the bot (mention-gating is off, so any message drives a turn).
    let msg_body = serde_json::json!({
        "msgtype": "m.text",
        "body": "daemonbot please respond to this round-trip probe",
    })
    .to_string();
    let txn = format!("m{}", Instant::now().elapsed().as_nanos());
    let sent = cs_api(
        &base,
        "PUT",
        &format!("/_matrix/client/v3/rooms/{room}/send/m.room.message/{txn}"),
        Some(&human.access_token),
        Some(&msg_body),
    );
    assert!(
        sent.and_then(|v| v.get("event_id").cloned()).is_some(),
        "the human's message should post to the room"
    );

    // The agent's reply is projected back into the room: poll for a bot-authored message event.
    let replied = poll_until(Duration::from_secs(60), || {
        let msgs = cs_api(
            &base,
            "GET",
            &format!("/_matrix/client/v3/rooms/{room}/messages?dir=b&limit=50"),
            Some(&human.access_token),
            None,
        );
        let Some(msgs) = msgs else { return false };
        let Some(chunk) = msgs.get("chunk").and_then(|c| c.as_array()) else {
            return false;
        };
        chunk.iter().any(|ev| {
            ev.get("type").and_then(|t| t.as_str()) == Some("m.room.message")
                && ev.get("sender").and_then(|s| s.as_str()) == Some(bot.user_id.as_str())
        })
    });
    assert!(
        replied,
        "the agent's reply should be projected back into the room by the bot account\ndaemon log:\n{}",
        daemon.log_contents()
    );
}
