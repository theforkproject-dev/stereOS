# Deploying stereOS

## From Mac to Digital Ocean

**A Technical Narrative**

Jason Amotivv · February 2026

---

## 1. What stereOS Actually Is

stereOS is a NixOS-based Linux distribution that produces VM images—called mixtapes—purpose-built to sandbox AI coding agents. Each mixtape bundles a hardened, minimal Linux system with a specific agent harness. The image boots in under three seconds, runs the agent in a locked-down environment, and provides a control plane for the host to inject secrets, mount directories, and coordinate shutdown.

The system has exactly two internal daemons. **stereosd** is the control plane: it listens on AF_VSOCK (or TCP as a fallback), handles secret injection to a tmpfs-backed directory, mounts shared filesystems, and manages lifecycle state. **agentd** reads a TOML configuration file, launches the agent binary inside a tmux session running as a restricted user, and supervises it with configurable restart policies. Neither daemon knows or cares what launched the VM. Any process that can send newline-delimited JSON over a socket can operate a stereOS instance.

This decoupling is the key architectural insight for deployment. There is no required orchestrator. The VM is self-contained once it has a config file and its secrets. You can manage it with a shell script, a purpose-built Go binary, or simply bake everything into the image at build time and let it start autonomously.

## 2. Building the Image on Your Mac

stereOS uses Nix flakes for fully reproducible builds. All dependencies are pinned in `flake.lock` to specific git commits. The build system supports four target architectures, but image output is always Linux:

| Format | Output | Use Case |
|--------|--------|----------|
| Raw EFI | `stereos.img` | Apple Virt Framework |
| QCOW2 | `stereos.qcow2` | QEMU / KVM / Cloud |
| Kernel Artifacts | `bzImage` + `initrd` | Direct-kernel boot (KVM) |

For Digital Ocean, you want the QCOW2 image. The default mixtape is `opencode-mixtape` and the default architecture is `aarch64-linux`. To build:

```bash
# Clone and enter the repository
git clone https://github.com/papercomputeco/stereOS.git
cd stereOS

# Build the QCOW2 image for x86_64 (Digital Ocean runs x86_64)
make build-qcow2 MIXTAPE=opencode-mixtape ARCH=x86_64-linux

# Or build the full distribution with checksums:
make dist MIXTAPE=opencode-mixtape ARCH=x86_64-linux
```

**Important:** The default architecture is `aarch64-linux` (ARM). Digital Ocean droplets are x86_64. You must pass `ARCH=x86_64-linux` or you will build an image that will not boot on their infrastructure. Nix handles the cross-compilation transparently—your Mac builds a Linux x86_64 image without needing a separate build machine.

The `dist` target produces a directory with all formats, zstd-compressed variants, and a `mixtape.toml` manifest containing SHA-256 checksums and file sizes for every artifact. Verify checksums before uploading anything to cloud infrastructure.

## 3. Customizing the Mixtape

The stock `opencode-mixtape` seeds a minimal OpenCode configuration and adds the `opencode` binary to the agent's restricted PATH. The actual mixtape file (`mixtapes/opencode/base.nix`) is straightforward:

```nix
# mixtapes/opencode/base.nix (as it exists in the repo)
{ config, lib, pkgs, ... }:
{
  stereos.agent.extraPackages = [ pkgs.opencode ];
  environment.systemPackages = [ pkgs.opencode ];

  environment.etc."skel/.config/opencode/config.json".text =
    builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
    };
}
```

If you need MCP servers that require Node.js (like Perplexity and Firecrawl, which spawn via `npx`), add Node.js to the agent's environment:

```nix
  stereos.agent.extraPackages = [
    pkgs.opencode
    pkgs.nodejs  # Enables npx for stdio-based MCP servers
  ];
```

Remote MCP servers (like Memory Box, which uses HTTPS with OAuth) work without any image modification — the agent has `curl`, TLS certificates, and outbound network access.

### Baking the Agent Config

You can bake the `jcard.toml` agent configuration directly into the image. agentd reads from `/etc/stereos/jcard.toml` (confirmed in stereosd's runtime directory layout). This eliminates the need to push config at runtime:

```nix
# profiles/autonomous.nix (new file)
{ ... }:
{
  environment.etc."stereos/jcard.toml".text = ''
    [agent]
    harness = "opencode"
    restart = "on-failure"
    max_restarts = 3
  '';
}
```

An image with a baked-in config becomes fully autonomous: boot it, inject secrets, and the agent starts working. No orchestrator needed.

### The Bootstrap Problem: SSH Access

**This is the critical gap for cloud deployment.** stereOS production images ship with no SSH keys baked in. Normally, stereosd handles SSH key injection over vsock from a local host. On Digital Ocean, you need SSH access to reach the VM at all — but DO injects SSH keys via cloud-init, which stereOS doesn't have.

You have two options:

**Option A: Bake an SSH key into the image.** Use the `stereos.ssh.authorizedKeys` option that already exists in the NixOS module:

```nix
# profiles/cloud.nix
{ ... }:
{
  stereos.ssh.authorizedKeys = [
    "ssh-ed25519 AAAA... your-deploy-key"
  ];
}
```

This key gets added to both the `admin` and `agent` users' `authorized_keys`. Use a dedicated deploy key, not your personal key. This is the pragmatic approach — the VM is ephemeral anyway.

**Option B: Add cloud-init to the NixOS config.** NixOS has cloud-init modules. This is cleaner but more work:

```nix
# profiles/cloud.nix
{ pkgs, ... }:
{
  services.cloud-init.enable = true;
  # DO provides metadata at http://169.254.169.254/metadata/v1/
}
```

This lets DO inject SSH keys at droplet creation time through its standard provisioning flow. It's the right long-term solution but requires testing to confirm compatibility with stereOS's hardened configuration.

**For initial testing, use Option A.** Bake a deploy key, validate the full workflow, then invest in cloud-init integration if you want to scale.

## 4. Getting the Image to Digital Ocean

Digital Ocean accepts custom images via their web console (drag-and-drop upload) or by URL import from an object store. For images larger than a few hundred MB, URL import is more reliable.

```bash
# Compress the image (if you used `make build-qcow2` instead of `make dist`)
zstd -19 -T0 result/stereos.qcow2

# Upload to Spaces
s3cmd put result/stereos.qcow2.zst \
  s3://your-bucket/stereos-opencode.qcow2.zst

# Import custom image via doctl
doctl compute image create stereos-opencode \
  --image-url https://your-bucket.nyc3.digitaloceanspaces.com/stereos-opencode.qcow2.zst \
  --region nyc3 \
  --image-distribution Unknown

# Create droplet from image
doctl compute droplet create agent-01 \
  --image <image-id> \
  --size s-2vcpu-4gb \
  --region nyc3 \
  --ssh-keys <your-key-fingerprint>
```

Note: If you baked an SSH key into the image (Option A above), the `--ssh-keys` flag in the `doctl` command won't do anything useful since there's no cloud-init to process it. Your baked-in key is what gets you in.

## 5. Runtime: Communicating with the VM

Once the droplet boots, stereosd starts listening. Its `--listen-mode auto` behavior checks for vsock availability first, then falls back to TCP. On Digital Ocean's KVM infrastructure, vsock via `vhost-vsock-pci` may or may not be available depending on the host configuration — this is untested. If vsock is unavailable, stereosd falls back to TCP on port 1024.

### The Wire Protocol

stereosd speaks NDJSON — one JSON object per line, maximum 1 MB per message. Every message is an envelope with a `type` field and an optional `payload`:

| Type | Direction | Purpose |
|------|-----------|---------|
| `ping` | host → guest | Health check; stereosd replies with `pong` |
| `get_health` | host → guest | Returns lifecycle state, uptime, and agent statuses |
| `inject_secret` | host → guest | Writes a secret to `/run/stereos/secrets/` (tmpfs, 0600) |
| `inject_ssh_key` | host → guest | Installs a public key to a user's `authorized_keys` |
| `set_config` | host → guest | Writes `jcard.toml` to `/etc/stereos/` for agentd |
| `mount` | host → guest | Mounts a virtio-fs or 9p shared directory |
| `shutdown` | host → guest | Graceful shutdown: unmount, sync, poweroff |
| `lifecycle` | guest → host | State transitions (push, no response expected) |

This protocol table comes directly from [stereosd's README](https://github.com/papercomputeco/stereosd), which documents the wire format authoritatively.

### Injecting Secrets

The NDJSON protocol over TCP has no encryption or authentication. **Never expose port 1024 to the public internet.** Tunnel through SSH:

```bash
# Open an SSH tunnel to stereosd's TCP port
ssh -L 1024:localhost:1024 admin@<droplet-ip> -N &

# Inject your API key through the tunnel
echo '{"type":"inject_secret","payload":{"name":"ANTHROPIC_API_KEY","value":"sk-ant-..."}}' \
  | nc localhost 1024

# Inject MCP server keys
echo '{"type":"inject_secret","payload":{"name":"PERPLEXITY_API_KEY","value":"pplx-..."}}' \
  | nc localhost 1024
echo '{"type":"inject_secret","payload":{"name":"FIRECRAWL_API_KEY","value":"fc-..."}}' \
  | nc localhost 1024
```

**Caveat on payload format:** The `inject_secret` payload fields shown above (`name`, `value`) are derived from Claude's analysis of stereosd's Go source code. They are consistent with stereosd's README description of the `SecretManager` subsystem, but the exact field names should be verified against the source before using this in production. The protocol envelope format (`{"type": "...", "payload": {...}}`) is confirmed in stereosd's documentation.

If you baked the `jcard.toml` into the image, agentd picks up the secrets from `/run/stereos/secrets/` on its next reconciliation cycle (it watches for changes via SHA-256 hashing) and restarts the agent with the new environment variables. If you didn't bake the config, push it with a `set_config` message before or after the secrets.

## 6. What Happens Inside the VM

The boot sequence, from power-on to agent running:

1. **GRUB loads the kernel and systemd-based initrd.** Kernel modules are restricted to virtio drivers and vsock transport. The initrd is parallelized via systemd (not the sequential bash stage-1).
2. **systemd-networkd brings up DHCP.** The wait-online service is disabled — the VM does not stall waiting for a full lease.
3. **stereosd starts,** detects the available transport (vsock or TCP), and begins listening. It creates `/run/stereos/secrets/` (0700, root-only) and sends a lifecycle message: `state=booting`.
4. **agentd starts** (after stereosd, enforced by systemd ordering), reads `/etc/stereos/jcard.toml`, resolves the prompt (inline or from a file), loads secrets from `/run/stereos/secrets/`, and launches the agent binary inside a tmux session as the `agent` user.
5. **stereosd polls agentd** every 5 seconds via the Unix socket at `/run/stereos/agentd.sock`. Once it sees a running agent, it transitions to `state=healthy` and notifies the host.
6. **The `stereos-ready` service** writes a nanosecond timestamp to `/run/stereos-ready`. The full boot-to-ready target is under 3 seconds.

The agent user has no sudo access (explicitly denied with `agent ALL=(ALL:ALL) !ALL`), no access to the Nix package manager (`allowed-users = ["root" "@wheel"]`), and a curated PATH of approximately 30 binaries: git, curl, jq, ripgrep, make, vim, tmux, htop, ssh client, and POSIX utilities. No compilers, no interpreters (unless you added Node.js for MCP servers), and no way to install new packages. The agent's login shell is a custom wrapper (`stereos-agent-shell`) that sets the restricted PATH, nukes all Nix environment variables, and execs into bash.

## 7. Scaling to a Fleet

Because the VM is stateless and the protocol is generic, scaling follows naturally. Each droplet is an independent agent sandbox. You can run a fleet by scripting the same workflow:

- Create N droplets from the same custom image.
- SSH-tunnel to each droplet's port 1024 (or use a WireGuard mesh for a persistent private network).
- Inject per-instance secrets and configs via the NDJSON protocol.
- Monitor lifecycle state via `get_health` messages or the IPC HTTP API (accessible over SSH at the Unix socket `/run/stereos/stereosd.sock`).
- Tear down with a `shutdown` message when the task is complete. The VM unmounts shared directories in reverse order, syncs filesystems, and powers off cleanly.

For baked-in config images, the workflow is even simpler: create the droplet and inject secrets. The agent starts working as soon as the secrets land. This is the pattern that makes stereOS practical for cloud deployment — each VM is a self-contained, ephemeral compute unit that needs nothing from you except credentials and a task.

### The IPC API Alternative

stereosd also exposes a local HTTP API on a Unix socket (`/run/stereos/stereosd.sock`, mode 0660, group `admin`). Over an SSH session, this is often easier to work with than raw NDJSON:

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/v1/ping` | Health check |
| `GET` | `/v1/health` | Full health payload (state, uptime, agents) |
| `POST` | `/v1/secrets` | Inject a secret |
| `GET` | `/v1/secrets` | List secret names |
| `DELETE` | `/v1/secrets/{name}` | Remove a secret |
| `GET` | `/v1/agents` | List agents (cached from agentd poller) |
| `POST` | `/v1/shutdown` | Graceful shutdown (returns 202 Accepted) |

```bash
# Over SSH, use curl against the Unix socket:
ssh admin@<droplet-ip> \
  'curl -s --unix-socket /run/stereos/stereosd.sock http://localhost/v1/health'
```

This avoids the TCP tunnel entirely for most operations.

## 8. Security Considerations for Cloud Deployment

stereOS was designed with local VM isolation in mind (vsock is inherently host-guest only). Moving to cloud infrastructure introduces the network as a trust boundary that the original design assumes away.

### Transport Security

The NDJSON protocol over TCP has no encryption or authentication. Never expose port 1024 to the public internet. Use SSH tunnels, a VPN, or Digital Ocean's VPC private networking to keep control plane traffic off the public network. API keys transit this channel during secret injection — if the transport is compromised, your keys are compromised.

The IPC Unix socket API (Section 7) avoids this concern entirely since it's only accessible from within the VM via SSH.

### Network Posture

Inside the VM, the guest firewall is intentionally disabled (`networking.firewall.enable = lib.mkForce false` in `boot.nix`). The design philosophy is that isolation is enforced at the VM boundary, not by iptables inside the guest. On Digital Ocean, this means the droplet's firewall configuration is your responsibility.

Use Digital Ocean's cloud firewall to:
- Allow inbound SSH (port 22) from your IP only
- Block port 1024 from all external sources — only allow it from your VPC or don't expose it at all (use the IPC socket over SSH instead)
- Consider restricting outbound to only the APIs the agent needs (LLM provider, MCP servers)

### Secret Lifecycle

Secrets live on tmpfs (`/run/stereos/secrets/`) and vanish when the VM powers off. This is ideal for ephemeral cloud instances. However, if the droplet is snapshotted while running, the snapshot could capture the contents of `/run` if the filesystem layer includes tmpfs in the snapshot. Avoid snapshotting running instances that have secrets injected.

### SSH Access

For cloud deployment, bake a dedicated deploy key into the image for initial access (Section 3). Consider rotating to ephemeral keys via stereosd's `inject_ssh_key` message once you have access — this way, the baked-in key is a bootstrap mechanism and per-session keys handle ongoing access. The production image (without the dev profile) ships with no SSH keys by default, which is the right posture for images that get distributed.

## 9. What's Untested

This guide is derived from source code analysis, not hands-on deployment. The following should be verified before treating this as a production runbook:

- **Cross-compilation on Mac to x86_64-linux** — Nix supports this, but stereOS's specific flake hasn't been tested this way by us
- **DO custom image boot** — stereOS images may need adjustments for DO's hypervisor (console configuration, virtio driver compatibility, disk label expectations)
- **vsock availability on DO** — `--listen-mode auto` should handle this gracefully (fall back to TCP), but it's unverified
- **cloud-init integration** — the NixOS module exists but hasn't been tested alongside stereOS's hardened config
- **NDJSON payload field names** — the envelope format is documented; the exact payload structures are from source code analysis
- **Image size** — stereOS images need to be under 100GB uncompressed for DO custom images. A minimal mixtape should be well under this, but verify

## 10. The Complete Workflow

From your Mac to a running agent on Digital Ocean:

| Step | Where | What |
|------|-------|------|
| 1 | Mac | Clone stereOS, customize mixtape, add SSH key to profile, build QCOW2 with `ARCH=x86_64-linux` |
| 2 | Mac | Upload compressed QCOW2 to Spaces or S3 |
| 3 | Digital Ocean | Import custom image, create cloud firewall, create droplet |
| 4 | Mac | SSH to droplet as admin; inject secrets via IPC socket or NDJSON tunnel |
| 5 | Inside VM | agentd detects secrets, starts OpenCode in tmux |
| 6 | Mac | Monitor via `/v1/health`; SSH as admin and `tmux attach` to observe agent |
| 7 | Mac | Send `shutdown` when task complete; destroy droplet |

The system is intentionally simple. There is no required orchestrator, no agent marketplace, no management dashboard. It is a hardened Linux VM with a JSON socket. Everything else — how you launch it, how you talk to it, how many you run — is up to you.

