# terraform/outputs.tf
#
# Outputs for stereOS Digital Ocean deployment.

output "droplet_id" {
  description = "Droplet ID"
  value       = digitalocean_droplet.stereos.id
}

output "droplet_ip" {
  description = "Public IPv4 address of the stereOS droplet"
  value       = digitalocean_droplet.stereos.ipv4_address
}

output "ssh_command" {
  description = "SSH command to connect as admin"
  value       = "ssh -i ~/.config/stereos/deploy-key admin@${digitalocean_droplet.stereos.ipv4_address}"
}

output "agent_ssh_command" {
  description = "SSH command to connect as agent"
  value       = "ssh -i ~/.config/stereos/deploy-key agent@${digitalocean_droplet.stereos.ipv4_address}"
}

output "health_command" {
  description = "Check stereOS health over SSH via IPC socket"
  value       = "ssh -i ~/.config/stereos/deploy-key admin@${digitalocean_droplet.stereos.ipv4_address} 'curl -s --unix-socket /run/stereos/stereosd.sock http://localhost/v1/health'"
}

output "image_id" {
  description = "Custom image ID"
  value       = digitalocean_custom_image.stereos.id
}
