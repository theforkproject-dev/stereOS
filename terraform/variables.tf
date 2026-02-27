# terraform/variables.tf
#
# Variables for stereOS Digital Ocean deployment.

variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "node_name" {
  description = "Droplet hostname"
  type        = string
  default     = "stereos-agent-01"
}

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "nyc1"
}

variable "size" {
  description = "Droplet size (2 vCPU / 4GB minimum for agent workloads)"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "image_name" {
  description = "Name for the custom image in DigitalOcean"
  type        = string
  default     = "stereos-opencode"
}

variable "image_url" {
  description = "Public URL to the QCOW2 image (Spaces, S3, or any HTTP URL). DO supports .gz and .bz2 but NOT .zst."
  type        = string
}

variable "mixtape" {
  description = "Mixtape name (for tagging and description only)"
  type        = string
  default     = "opencode-mixtape"
}

variable "ssh_key_id" {
  description = "SSH key ID registered in DigitalOcean (doctl compute ssh-key list)"
  type        = string
}

variable "allowed_ssh_ips" {
  description = "IP addresses allowed to SSH (lock to your IP with [\"YOUR_IP/32\"])"
  type        = list(string)
  default     = ["47.39.133.151/32"]
}

variable "enable_backups" {
  description = "Enable automated DO backups"
  type        = bool
  default     = false
}

variable "project_name" {
  description = "DigitalOcean project name for resource grouping"
  type        = string
  default     = "stereOS"
}
