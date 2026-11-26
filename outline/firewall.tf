resource "google_compute_firewall" "outline" {
  name      = var.firewall_name
  network   = var.network
  direction = "INGRESS"
  priority  = 1000

  source_ranges = var.firewall_source_ranges
  target_tags   = [var.tag_name]

  allow {
    protocol = "tcp"
    ports    = var.outline_tcp_ports
  }

  allow {
    protocol = "udp"
    ports    = var.outline_udp_ports
  }
}

# SSH access so Terraform can run postscript.sh on the instances.
# When close_ssh_after_install is true, provision.tf turns this rule on before
# the install and off after it, so port 22 is closed the rest of the time.
resource "google_compute_firewall" "outline_ssh" {
  name      = "${var.firewall_name}-ssh"
  network   = var.network
  direction = "INGRESS"
  priority  = 1000

  source_ranges = var.ssh_source_ranges
  target_tags   = [var.tag_name]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Turned on/off by provision.tf with gcloud; don't let Terraform undo that.
  lifecycle {
    ignore_changes = [disabled]
  }
}
