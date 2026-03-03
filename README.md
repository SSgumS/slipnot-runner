# 🌊 Slipnot Runner

> *We call it Slipnot because it's shorter and more fun — ...*

A Bash process manager for [Slipstream](https://github.com/nicholasgasior/slipstream) DNS-over-HTTPS tunnels — keeps clients and servers alive in unreliable or censored networks with automatic health checking, multi-client orchestration, resolver rotation, and hot-reloading.

> 🛠️ A companion `disable_dns.sh` is included to free port 53 on Ubuntu by disabling `systemd-resolved`'s stub listener. Run once before starting the server: `sudo ./disable_dns.sh`

---

## ✨ Features

- 🔄 **Process supervision** — auto-restart on crash, connection close, or health-check failure
- 📡 **Multi-client orchestration** — N parallel clients on sequential ports, independently managed
- 🩺 **Health checking** — periodic `curl` probes per client with configurable interval, threshold, and extra success codes
- ♻️ **Smart resolver rotation** — on failure, prefers fresh resolvers unused by other clients before falling back
- ➕ **Plus mode** — native support for the multi-resolver Slipstream Plus fork (`-rc` per-client assignment)
- 📂 **File-based resolvers + hot-reload** — load from prioritized files, re-read every 30s, hot-swap without restart
- 🧹 **Graceful cleanup** — traps `SIGINT`/`SIGTERM`/`EXIT`, kills entire process group

---

## 📋 Prerequisites

- **Bash 4+** (uses associative arrays)
- **curl** (health checks)
- Slipstream binaries in the working directory:
  - Standard: `slipnot-server`, `slipnot-client`
  - Plus (`-p`): `slipnotp-server`, `slipnotp-client`
- **BBR congestion control** enabled in kernel (hardcoded `-c bbr`)

---

## 🚀 Usage

```
./run.sh [OPTIONS] {server|client} [resolver1 resolver2 ...]
```

Run `./run.sh -h` for the full options reference. All flags are **position-independent**.

### 🖥️ Server Mode

Starts the server and health-checks it via a loopback client + periodic test connections. Restarts automatically on repeated failures.

**Required files in working directory:**

| File | Purpose |
|---|---|
| 📜 `fullchain.pem` | TLS certificate chain |
| 🔑 `privkey.pem` | TLS private key |

> ⚠️ These are passed to the binary automatically — **no CLI flags** for them. A `reset-seed` file is also used if present; Slipstream auto-generates it otherwise.

**Health-check internals:** a loopback client connects on port `5202`, with a secondary test client on `5203`. After 3 consecutive loopback-client start failures → server restart. Every 5 cycles a fresh test connection is attempted; 5 consecutive test failures → full server restart.

### 📱 Client Mode

Manages one or more client instances with log-based event detection (`Connection ready` / `Connection close`) and automatic rotation.

**Implicit behaviors (not in `--help`):**

| Behavior | Detail |
|---|---|
| 🌐 Default resolvers | `2.188.21.130:53`, `8.8.8.8:53` when none specified |
| 🔒 Auto TLS cert | `./cert.pem` in working dir → auto-passed as `--cert` |
| 📉 Client count capping | Capped to available resolvers (or `⌊resolvers / rc⌋` in plus mode) with a warning |
| ⏱️ Keep-alive interval | Hardcoded to 50s (`-t 50`) |
| 🔗 HC port injection | Port in `-hc` URL is replaced per client automatically |
| ♻️ Rotation strategy | Fresh unused resolvers first → fall back to previous set |
| 📂 File monitor | Re-reads every 30s; defaults to `benchmark.txt` when `-f` is given without a filename; threshold (`-ft`) distributed by file priority with redistribution pass |

### 📝 Logging

- **Client mode** → `./slipnot_client.log` — consolidated, prefixed per client (`[Client N :PORT]`)
- **Server mode** → `./health_client.log` and `./test_client.log` for health-check clients

### 💡 Examples

```bash
# Server with defaults
./run.sh server

# 3 clients, custom resolvers
./run.sh -c 3 client 1.1.1.1:53 8.8.8.8:53 9.9.9.9:53

# Plus mode: 2 clients × 2 resolvers each
./run.sh -p -c 2 -rc 2 client 1.1.1.1:53 8.8.8.8:53 9.9.9.9:53 208.67.222.222:53

# File-based resolvers, two prioritized files
./run.sh -f benchmark.txt -f backup.txt -ft 12 client
```

---

## ⚠️ Caveats

- Server health-check ports (`5202`/`5203`) are hardcoded — avoid overlapping with client `BASE_PORT` range
- BBR requires kernel-level support; verify with `sysctl net.ipv4.tcp_available_congestion_control`
- File-mode resolver files must contain one `host:port` per line (comments with `#`, blank lines ignored)

---

## 🙏 Credits

- [Slipstream Rust](https://github.com/nicholasgasior/slipstream) — original DNS-over-HTTPS tunnel
- [Slipstream Rust Plus](https://github.com/nicholasgasior/slipstream-rust-plus) — multi-resolver fork
