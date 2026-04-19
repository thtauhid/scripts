# scripts

Personal provisioning scripts for quickly bootstrapping new Linux machines (VMs, LXCs, bare metal) with common tools and cache configurations.

## `setup.sh`

Installs and configures:

- **Docker** (official Docker CE from `download.docker.com`)
- **Docker registry mirror** — points Docker at a local pull-through cache
- **Tailscale** (official install script from `tailscale.com/install.sh`)
- **apt proxy** — routes `apt` through a local `apt-cacher-ng` instance

Supports both **interactive** and **unattended** modes.

### Supported distros

- Ubuntu
- Debian

The script auto-detects via `/etc/os-release` and bails on anything else.

---

## Quick copy-paste

### Full unattended setup (everything, with Tailscale)

```bash
curl -sSL https://raw.githubusercontent.com/thtauhid/scripts/main/setup.sh | sudo bash -s -- \
  --yes --all \
  --host=192.168.0.123 \
  --tailscale-authkey=tskey-auth-REPLACE_ME
```

### Full unattended setup (everything, no Tailscale auto-connect)

```bash
curl -sSL https://raw.githubusercontent.com/thtauhid/scripts/main/setup.sh | sudo bash -s -- \
  --yes --all \
  --host=192.168.0.123
```

### Interactive (asks about each component)

```bash
curl -sSL https://raw.githubusercontent.com/thtauhid/scripts/main/setup.sh | sudo bash
```

---

## Usage

### Interactive (default)

Prompts `[Y/n]` for each component (default **Yes** — hit Enter to accept). If any cache-related component is enabled and no host was passed, it'll ask for the cache host.

```bash
curl -sSL https://raw.githubusercontent.com/thtauhid/scripts/main/setup.sh | sudo bash
```

### Unattended

Opt-in via flags. Only components whose flags are passed will be installed/configured.

```bash
# Just the apt proxy
curl -sSL https://raw.githubusercontent.com/thtauhid/scripts/main/setup.sh | sudo bash -s -- \
  --yes --apt-proxy --host=192.168.0.123

# Everything, Tailscale auto-connect
curl -sSL https://raw.githubusercontent.com/thtauhid/scripts/main/setup.sh | sudo bash -s -- \
  --yes --all --host=192.168.0.123 --tailscale-authkey=tskey-xxxxx
```

### Local execution

If you've already cloned the repo or copied the script:

```bash
sudo ./setup.sh                                   # interactive
sudo ./setup.sh --yes --all --host=192.168.0.123  # unattended
```

---

## Flags

### Modifiers

| Flag | Description |
|---|---|
| `--yes`, `-y` | Unattended mode. No prompts. Only components whose flags are passed will run. |
| `--help`, `-h` | Show help. |

### Component flags (unattended only)

All default to OFF. Pass only what you want. In interactive mode these are ignored and the script prompts per-component.

| Flag | Description |
|---|---|
| `--docker` | Install Docker CE + compose plugin |
| `--docker-mirror` | Write `/etc/docker/daemon.json` with registry mirror (needs a cache host) |
| `--tailscale` | Install Tailscale |
| `--apt-proxy` | Write `/etc/apt/apt.conf.d/01proxy` with apt-cacher-ng proxy (needs a cache host) |
| `--all` | Shorthand for `--docker --docker-mirror --tailscale --apt-proxy` |

### Cache host / URL flags

No defaults. Pass one of these when using `--docker-mirror` or `--apt-proxy`.

| Flag | Description |
|---|---|
| `--host=HOST` | Single cache host used for **both** Docker mirror (port **5000**) and apt proxy (port **3142**). Easiest option when both services are on the same machine. |
| `--docker-mirror-url=URL` | Full URL override for Docker registry mirror. Takes precedence over `--host`. |
| `--apt-proxy-url=URL` | Full URL override for apt proxy. Takes precedence over `--host`. |

Precedence (highest wins): explicit `*-url` flag → `--host` + default port → interactive prompt → error.

### Other

| Flag | Description |
|---|---|
| `--tailscale-authkey=KEY` | Reusable Tailscale auth key. If set, runs `tailscale up --authkey=...` automatically. |

---

## What each component does

### Docker

Installs from Docker's official apt repo (not the distro-shipped `docker.io`). Gets `docker-ce`, `docker-ce-cli`, `containerd.io`, and the `docker-compose-plugin` (so `docker compose` works).

Skipped if `docker` is already on `PATH`.

### Docker registry mirror

Writes `/etc/docker/daemon.json`:

```json
{
  "registry-mirrors": ["http://<host>:5000"]
}
```

Then restarts the Docker daemon. All subsequent pulls from Docker Hub go through the cache server first — first pull populates the cache over WAN, subsequent pulls are served at LAN speed.

Requires Docker to be installed (will warn and skip if not).

### Tailscale

Installs via `curl -fsSL https://tailscale.com/install.sh | sh`.

Connection behavior:

- If `--tailscale-authkey=...` is passed → auto-runs `tailscale up --authkey=...`
- In interactive mode with no auth key → prompts whether to run `tailscale up` (which prints a browser auth URL)
- In unattended mode with no auth key → installs only; prints a reminder to run `sudo tailscale up` later

Generate reusable auth keys from the [Tailscale admin console](https://login.tailscale.com/admin/settings/keys).

### apt proxy

Writes `/etc/apt/apt.conf.d/01proxy`:

```
Acquire::http::Proxy "http://<host>:3142";
Acquire::https::Proxy "DIRECT";
```

HTTP repos route through the cache. HTTPS bypasses it — apt-cacher-ng can't meaningfully cache HTTPS without MITM tricks that aren't worth the setup hassle. Most `apt update` traffic is HTTP anyway, so the cache still pays off.

Runs **first** in the script so Docker's subsequent `apt install` can also benefit from it.

---

## Default ports

If you only pass `--host=HOST`, these ports are assumed:

| Service | Port |
|---|---|
| Docker registry mirror | `5000` |
| apt-cacher-ng | `3142` |

If your setup uses different ports, use `--docker-mirror-url=` or `--apt-proxy-url=` to specify the full URL.

---

## Idempotency

Safe to re-run.

- Docker install is skipped if already installed.
- Tailscale install is skipped if already installed.
- `daemon.json` and `01proxy` are **always overwritten** — so re-running with a different host or URL will update the config cleanly.

---

## Examples

```bash
# LXC dev box — just apt proxy
curl -sSL https://raw.githubusercontent.com/thtauhid/scripts/main/setup.sh | sudo bash -s -- \
  --yes --apt-proxy --host=192.168.0.123

# Docker workload VM — cache setup only, no Tailscale
curl -sSL https://raw.githubusercontent.com/thtauhid/scripts/main/setup.sh | sudo bash -s -- \
  --yes --apt-proxy --docker --docker-mirror --host=192.168.0.123

# Just Docker, no cache
curl -sSL https://raw.githubusercontent.com/thtauhid/scripts/main/setup.sh | sudo bash -s -- \
  --yes --docker

# Different cache hosts for Docker vs apt
curl -sSL https://raw.githubusercontent.com/thtauhid/scripts/main/setup.sh | sudo bash -s -- \
  --yes --apt-proxy --docker-mirror \
  --apt-proxy-url=http://apt.local:3142 \
  --docker-mirror-url=http://docker.local:5000

# Custom Docker mirror port
curl -sSL https://raw.githubusercontent.com/thtauhid/scripts/main/setup.sh | sudo bash -s -- \
  --yes --docker --docker-mirror \
  --docker-mirror-url=http://192.168.0.123:5001
```

---

## Caveats

- **Root required.** Script exits if not run as root.
- **HTTP mirror is insecure by default.** Docker is happy with HTTP registry mirrors on a LAN, but don't expose the cache server to the internet.
- **Auth keys are sensitive.** Don't commit `tskey-...` values to the repo. Pass them via CLI flags or env vars at runtime.
- **HTTPS apt repos bypass the cache.** This includes Docker's own apt repo. It's a limitation of apt-cacher-ng, not the script.
