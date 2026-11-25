# Look up the available zones in each requested region and use the first one.
data "google_compute_zones" "available" {
  for_each = toset(var.regions)

  region = each.key
  status = "UP"
}

resource "google_compute_instance" "outline" {
  for_each = toset(var.regions)

  name         = "${var.instance_name_prefix}-${each.key}"
  machine_type = var.machine_type
  zone         = sort(data.google_compute_zones.available[each.key].names)[0]

  tags   = var.tags
  labels = var.labels

  boot_disk {
    auto_delete = true
    device_name = "${var.instance_name_prefix}-${each.key}"
    mode        = "READ_WRITE"

    initialize_params {
      image = var.boot_image
      size  = var.boot_disk_size_gb
      type  = var.boot_disk_type
    }
  }

  network_interface {
    # The auto-mode "default" network has a subnet with this name in every region.
    subnetwork = "projects/${var.project_id}/regions/${each.key}/subnetworks/${var.subnetwork}"
    stack_type = "IPV4_ONLY"

    # Ephemeral external IP on the Standard network tier.
    access_config {
      network_tier = "STANDARD"
    }
  }

  scheduling {
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
    automatic_restart   = true
    preemptible         = false
  }

  service_account {
    email  = var.service_account_email
    scopes = var.scopes
  }

  shielded_instance_config {
    enable_secure_boot          = false
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  reservation_affinity {
    type = "ANY_RESERVATION"
  }
}
