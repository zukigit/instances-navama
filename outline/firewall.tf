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

  # Outline is installed on outline_api_port (TCP) and outline_keys_port (TCP
  # and UDP); stop the plan if this rule wouldn't let them through.
  lifecycle {
    precondition {
      condition     = local.ports_open
      error_message = "The firewall doesn't open Outline's ports: outline_tcp_ports must include outline_api_port (${var.outline_api_port}) and outline_keys_port (${var.outline_keys_port}), and outline_udp_ports must include outline_keys_port."
    }
  }
}

locals {
  # Is port p in a firewall port list? Entries are single ports or ranges ("9000-9500").
  tcp_has = { for p in [var.outline_api_port, var.outline_keys_port] : tostring(p) => anytrue([
    for e in var.outline_tcp_ports : length(split("-", e)) == 2
    ? (p >= tonumber(split("-", e)[0]) && p <= tonumber(split("-", e)[1]))
    : tonumber(e) == p
  ]) }
  udp_has_keys = anytrue([
    for e in var.outline_udp_ports : length(split("-", e)) == 2
    ? (var.outline_keys_port >= tonumber(split("-", e)[0]) && var.outline_keys_port <= tonumber(split("-", e)[1]))
    : tonumber(e) == var.outline_keys_port
  ])
  ports_open = alltrue(values(local.tcp_has)) && local.udp_has_keys
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
