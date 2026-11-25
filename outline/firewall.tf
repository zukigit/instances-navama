resource "google_compute_firewall" "outline" {
  name      = "allow-outline"
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
