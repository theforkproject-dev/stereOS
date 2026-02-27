# Deploying stereOS to Digital Ocean

A tested, end-to-end guide for running stereOS agent sandboxes on Digital Ocean droplets.

Last verified: February 2026

---

## Overview

stereOS is a NixOS-based Linux distribution that produces immutable VM images (called "mixtapes") for sandboxing AI coding agents. Each image boots in under 3 seconds with two daemons:

- **stereosd** — control plane (secret injection, health, lifecycle)
- **agentd** — reads a TOML config file, launches the agent in a tmux session, supervises restarts

The upstream project targets local VMs (Apple Virtualization, QEMU) on aarch64. This guide covers adapting it for x86_64 cloud deployment on Digital Ocean's KVM infrastructure.

## What We Changed (and Why)

Upstream stereOS images are EFI-only (GPT partition table + ESP, GRUB with `device = "nodev"`). Digital Ocean uses SeaBIOS (BIOS boot), which hangs at "Booting from Hard Disk..." with no MBR bootloader. The `profiles/cloud.nix` module fixes this and handles other cloud-specific concerns:

| Problem | Fix in cloud.nix |
|---------|------------------|
| DO uses SeaBIOS, not UEFI | GRUB installs to MBR of `/dev/vda` |
| EFI partition table incompatible | MBR (legacy) partition table |
| No cloud-init for SSH key injection | Bake an ed25519 deploy key at build time |
| Serial console is ttyAMA0 (ARM) | Append `console=ttyS0,115200` for x86_64 KVM |
| All gettys disabled for fast boot | Re-enable serial-getty on ttyS0 for DO web console |

These are the only NixOS config changes. agentd and stereosd are unmodified from upstream.

## Prerequisites

- A Digital Ocean account with an API token
- A DO Spaces bucket (for hosting the built image)
- `terraform`, `gh` (GitHub CLI), and `aws` CLI installed locally
- An SSH deploy keypair for VM access

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  GitHub Actions (ubuntu-latest)                     │
│  ┌───────────────────────────────────────────────┐  │
│  │ Nix builds x86_64-linux QCOW2 from flake     │  │
│  │ cloud.nix provides BIOS boot + SSH key        │  │
│  │ Output: stereos.qcow2.gz (~650MB)             │  │
│  └───────────────────────────────────────────────┘  │
│                        │ artifact                    │
└────────────────────────┼────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────┐
│  DO Spaces (object storage)                         │
│  Pre-signed URL → Terraform imports as custom image │
└────────────────────────┬────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│  DO Droplet (s-2vcpu-4gb, nyc1)                     │
│  ┌─────────────┐  ┌──────────┐  ┌───────────────┐  │
│  │  stereosd    │  │  agentd  │  │  sshd         │  │
│  │  (control)   │  │  (agent  │  │  (admin/agent │  │
│  │              │  │  super.) │  │   access)     │  │
│  └─────────────┘  └──────────┘  └───────────────┘  │
│  Cloud firewall: SSH only from your IP              │
└─────────────────────────────────────────────────────┘
```

## Step 1: Fork the Repos

Fork all three repositories from `papercomputeco` to your GitHub account. This gives you upstream tracking and satisfies AGPL-3.0 source availability if you ever distribute or offer as a service.

```bash
# Fork via GitHub UI or CLI
gh repo fork papercomputeco/stereOS --clone=false
gh repo fork papercomputeco/agentd --clone=false
gh repo fork papercomputeco/stereosd --clone=false
```

Clone your stereOS fork locally and add the upstream remote:

```bash
git clone https://github.com/YOUR_ORG/stereOS.git
cd stereOS
git remote add upstream https://github.com/papercomputeco/stereOS.git
```

## Step 2: Create the Cloud Branch

All cloud deployment changes live on a `cloud` branch, keeping `main` clean for upstream syncing.

```bash
git checkout -b cloud
```

### 2a. Update Flake Inputs

Edit `flake.nix` to point the `agentd` and `stereosd` inputs at your forks:

```nix
agentd = {
  url = "github:YOUR_ORG/agentd";
  inputs.nixpkgs.follows = "nixpkgs";
};

stereosd = {
  url = "github:YOUR_ORG/stereosd";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

### 2b. Add Cloud NixOS Configurations

Add cloud configurations to the `nixosConfigurations` block in `flake.nix`. These use `system = "x86_64-linux"` and include `profiles/cloud.nix`:

```nix
# -- Cloud configurations (x86_64, SSH deploy key) --------------------
opencode-mixtape-cloud = stereos-lib.mkMixtape {
  name = "opencode-mixtape";
  system = "x86_64-linux";
  features = [ ./mixtapes/opencode/base.nix ];
  extraModules = [ ./profiles/cloud.nix ];
};
```

Repeat for any other mixtapes you want cloud variants of (claude-code, gemini-cli, full).

### 2c. Create profiles/cloud.nix

This is the core cloud adaptation. See `profiles/cloud.nix` in this repository for the full implementation. Key sections:

- **BIOS/MBR boot**: Overrides GRUB to install to `/dev/vda` MBR instead of EFI
- **MBR disk image**: Replaces the GPT+ESP raw image with a legacy partition table
- **SSH deploy key**: Reads from `~/.config/stereos/deploy-key.pub` at build time
- **Serial console**: Appends `console=ttyS0,115200` to kernel params
- **Getty**: Re-enables serial-getty on ttyS0 for the DO web console

### 2d. Update flake/images.nix for Multi-Arch

The upstream `images.nix` only targets aarch64-linux. Update it to also produce packages for x86_64-linux. The cloud configurations need `x86_64-linux` packages to appear in the flake output.

### 2e. Add the CI Workflow

Create `.github/workflows/build-image.yml` (see the file in this repository). The workflow:

1. Checks out the repo
2. Installs Nix with flakes enabled
3. Writes the deploy SSH public key from a GitHub secret
4. Runs `nix build .#packages.x86_64-linux.<mixtape>-qcow2 --impure`
5. Compresses with gzip (DO doesn't support `.zst`)
6. Uploads as a GitHub Actions artifact

**Important**: The workflow file must exist on your default branch (`main`) for GitHub to discover it in the Actions UI. Push it to both `main` and `cloud`.

### 2f. Required GitHub Actions Secrets

Set these on your stereOS fork (Settings > Secrets and variables > Actions):

| Secret | Value |
|--------|-------|
| `DEPLOY_SSH_PUBKEY` | Contents of your `~/.config/stereos/deploy-key.pub` |
| `NIX_ACCESS_TOKENS` | `github.com=ghp_your_github_pat` (needs repo read access to your agentd/stereosd forks) |

## Step 3: Generate Your Deploy Key

```bash
mkdir -p ~/.config/stereos
ssh-keygen -t ed25519 -f ~/.config/stereos/deploy-key -C "stereos-deploy"
```

This key gets baked into the image at build time. It provides SSH access to both the `admin` and `agent` users on the VM.

## Step 4: Build the Image

Trigger the CI workflow from GitHub Actions (your repo > Actions > Build Image > Run workflow). Select:

- **Mixtape**: `opencode-mixtape-cloud` (or whichever agent you want)
- **Architecture**: `x86_64-linux`

The build takes approximately 5-7 minutes on `ubuntu-latest`. The output is a gzip-compressed QCOW2 (~650MB).

Download the artifact:

```bash
# Find the run ID
gh run list --repo YOUR_ORG/stereOS --workflow build-image.yml --limit 5

# Download
gh run download <RUN_ID> --repo YOUR_ORG/stereOS --dir /tmp/stereos-build/
```

## Step 5: Upload to DO Spaces

Create a Spaces bucket if you don't have one:

```bash
# Using doctl
doctl spaces create stereos-images --region nyc3
```

Configure AWS CLI with your Spaces access keys:

```bash
aws configure --profile spaces
# Access Key ID: your DO Spaces key
# Secret Access Key: your DO Spaces secret
# Region: nyc3
# Output format: json
```

Upload and generate a pre-signed URL:

```bash
# Upload
aws s3 cp /tmp/stereos-build/stereos-opencode-mixtape-cloud-x86_64-linux/stereos.qcow2.gz \
  s3://stereos-images/opencode-mixtape-cloud-x86_64-linux/stereos.qcow2.gz \
  --endpoint-url https://nyc3.digitaloceanspaces.com --profile spaces

# Generate pre-signed URL (valid 2 hours)
aws s3 presign s3://stereos-images/opencode-mixtape-cloud-x86_64-linux/stereos.qcow2.gz \
  --endpoint-url https://nyc3.digitaloceanspaces.com --expires-in 7200 --profile spaces
```

Use pre-signed URLs to avoid making the bucket or object public. The URL only needs to be valid long enough for Terraform to import the image (~3-5 minutes).

## Step 6: Deploy with Terraform

### 6a. Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
do_token        = "dop_v1_your_token"
image_url       = "https://nyc3.digitaloceanspaces.com/...your-presigned-url..."
ssh_key_id      = "YOUR_SSH_KEY_ID"    # doctl compute ssh-key list
allowed_ssh_ips = ["YOUR_IP/32"]       # curl ifconfig.me
```

### 6b. Deploy

```bash
terraform init
terraform plan    # Review what will be created
terraform apply   # Creates: custom_image, droplet, firewall, project
```

Terraform creates four resources:

1. **Custom image** — imports the QCOW2 from the pre-signed URL (~3 min)
2. **Droplet** — boots from the custom image (~20 sec)
3. **Firewall** — SSH only from your IP, all outbound permitted
4. **Project** — groups resources in the DO dashboard

The output includes your SSH command:

```
ssh_command = "ssh -i ~/.config/stereos/deploy-key admin@<DROPLET_IP>"
```

## Step 7: Verify

```bash
# SSH in and check services
ssh -i ~/.config/stereos/deploy-key admin@<DROPLET_IP>

# On the droplet:
systemctl status stereosd agentd sshd

# Check health via stereosd's IPC socket
curl -s --unix-socket /run/stereos/stereosd.sock http://localhost/v1/health
```

All three services (stereosd, agentd, sshd) should be active. agentd will be logging "config not available" every 5 seconds until you write the agent config.

## Step 8: Configure the Agent

### 8a. Write jcard.toml

agentd reads `/etc/stereos/jcard.toml` every 5 seconds. Write it:

```bash
ssh -i ~/.config/stereos/deploy-key admin@<DROPLET_IP> \
  'sudo tee /etc/stereos/jcard.toml > /dev/null <<EOF
[agent]
harness = "opencode"
restart = "on-failure"
max_restarts = 5
grace_period = "30s"
EOF'
```

**jcard.toml fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `harness` | Yes | Agent binary: `opencode`, `claude-code`, `gemini-cli`, or `custom` |
| `prompt` | No | Initial prompt to send on boot (empty = interactive mode) |
| `prompt_file` | No | Path to a prompt file (takes precedence over `prompt`) |
| `workdir` | No | Working directory (default: `/home/agent/workspace`) |
| `restart` | No | `no` (default), `on-failure`, or `always` |
| `max_restarts` | No | Max consecutive restart attempts, 0 = unlimited |
| `timeout` | No | Max agent runtime (e.g., `"2h"`), unset = no limit |
| `grace_period` | No | SIGTERM-to-SIGKILL wait (default: `"30s"`) |
| `session` | No | tmux session name (default: harness name) |
| `env` | No | Extra environment variables as key-value pairs |

### 8b. Inject Secrets

agentd reads secrets from `/run/stereos/secrets/` — each file becomes an environment variable (filename = var name, content = value).

```bash
ssh -i ~/.config/stereos/deploy-key admin@<DROPLET_IP> \
  'echo -n "sk-ant-your-key" | sudo tee /run/stereos/secrets/ANTHROPIC_API_KEY > /dev/null'
```

Secrets live on tmpfs and vanish when the VM powers off. agentd detects new secrets via SHA-256 hashing and restarts the agent with the updated environment.

### 8c. Observe the Agent

```bash
# SSH as the agent user and attach to the tmux session
ssh -i ~/.config/stereos/deploy-key agent@<DROPLET_IP>
tmux attach -t opencode
```

## Updating the Image

The VM image is immutable. Any NixOS configuration change requires a full rebuild cycle:

1. Push changes to the `cloud` branch
2. Trigger CI build
3. Download artifact, upload to Spaces, generate pre-signed URL
4. `terraform apply` (replaces the custom image and droplet)

**For minor upstream patches**: sync the git changes to stay current, but defer rebuilding until there's a meaningful reason (security fix, structural change, new features). The rebuild cycle is heavy for small changes.

```bash
# Sync upstream without rebuilding
git fetch upstream
git checkout main && git merge upstream/main && git push origin main
git checkout cloud && git rebase main && git push origin cloud --force-with-lease
```

## Tearing Down

```bash
cd terraform
terraform destroy
```

This removes the droplet, firewall, custom image, and project. Secrets on tmpfs are gone the moment the droplet is destroyed.

## Security Notes

- **Guest firewall is disabled** (`boot.nix` sets `networking.firewall.enable = lib.mkForce false`). The DO cloud firewall is your only network boundary.
- **stereosd TCP fallback** listens on port 1024 when vsock is unavailable (expected on DO KVM). This port is blocked by the firewall — use the IPC Unix socket over SSH instead.
- **Secrets on tmpfs** are lost on reboot/shutdown. Do not snapshot running droplets with injected secrets.
- **The agent user** has no sudo, no access to the Nix store, and a restricted PATH of ~30 binaries. It cannot install packages or escalate privileges.
- **DO custom images don't support IPv6** — Terraform sets `ipv6 = false` to avoid a 422 error.

## File Reference

| File | Purpose |
|------|---------|
| `profiles/cloud.nix` | BIOS boot, MBR partition, SSH key, serial console |
| `flake.nix` | Cloud nixosConfigurations (x86_64-linux) |
| `flake/images.nix` | Multi-arch package outputs |
| `.github/workflows/build-image.yml` | CI build workflow |
| `terraform/main.tf` | DO provider, image, droplet, firewall, project |
| `terraform/variables.tf` | All deployment variables with defaults |
| `terraform/outputs.tf` | Droplet IP, SSH commands, health check |
| `terraform/terraform.tfvars.example` | Template for your credentials |
