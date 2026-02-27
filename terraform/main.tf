# terraform/main.tf
#
# stereOS on Digital Ocean.
#
# Deploys a pre-built stereOS QCOW2 image as a custom image, creates a
# droplet from it, and wraps it in a cloud firewall.
#
# Unlike fork-ops, there is no cloud-init, no block storage volume, and
# no reserved IP. The NixOS image IS the provisioning — it boots in
# under 3 seconds and is ready to accept secrets via stereosd.
#
# Usage:
#   cd terraform
#   cp terraform.tfvars.example terraform.tfvars
#   # Edit terraform.tfvars with your values
#   terraform init
#   terraform apply

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

# -----------------------------------------------------------------------------
# Custom Image — pre-built stereOS QCOW2 uploaded to Spaces or any URL
# -----------------------------------------------------------------------------
# DO supports .gz and .bz2 decompression on import. It does NOT support
# .zst — either upload uncompressed or gzip-compress the image.
resource "digitalocean_custom_image" "stereos" {
  name         = var.image_name
  url          = var.image_url
  regions      = [var.region]
  distribution = "Unknown"
  description  = "stereOS ${var.mixtape} image"

  timeouts {
    create = "30m"
  }

  tags = ["stereos"]
}

# -----------------------------------------------------------------------------
# Firewall
# -----------------------------------------------------------------------------
# Design: SSH only from allowed IPs. All outbound permitted (agent needs
# LLM API access). No inbound on port 1024 — use the IPC Unix socket
# over SSH instead of exposing the NDJSON TCP transport.
resource "digitalocean_firewall" "stereos" {
  name        = "${var.node_name}-firewall"
  droplet_ids = [digitalocean_droplet.stereos.id]

  # Inbound: SSH from allowed IPs only
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.allowed_ssh_ips
  }

  # Outbound: all TCP (LLM APIs, MCP servers, package registries)
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Outbound: all UDP (DNS, NTP)
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Outbound: ICMP (ping)
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  tags = ["stereos"]
}

# -----------------------------------------------------------------------------
# Droplet
# -----------------------------------------------------------------------------
# No user_data — the image is fully configured at build time.
# No volume — stereOS agents are ephemeral.
# The ssh_keys field associates the key with the droplet in DO's dashboard
# but does NOT inject it (no cloud-init). Access uses the key baked into
# the image via profiles/cloud.nix.
resource "digitalocean_droplet" "stereos" {
  name    = var.node_name
  region  = var.region
  size    = var.size
  image   = digitalocean_custom_image.stereos.id
  backups = var.enable_backups
  ipv6    = false

  ssh_keys = [var.ssh_key_id]

  tags = ["stereos"]

  depends_on = [digitalocean_custom_image.stereos]
}

# -----------------------------------------------------------------------------
# Project (organizes resources in DO dashboard)
# -----------------------------------------------------------------------------
resource "digitalocean_project" "stereos" {
  name        = var.project_name
  description = "stereOS agent sandbox infrastructure"
  purpose     = "Service or API"
  environment = "Production"

  resources = [
    digitalocean_droplet.stereos.urn,
  ]
}
