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

  tags   = [var.tag_name]
  labels = var.labels

  # SSH key Terraform uses to run postscript.sh (see provision.tf).
  # OS Login is turned off for these VMs so the key in metadata is accepted.
  #
  # Boot script (startup.sh.tftpl), run at every boot:
  #   - run_hours > 0: shuts the VM down after that many hours
  #   - run_postscript: points Outline's access keys at the new external IP
  #     when it changed (ephemeral IPs change on every stop/start)
  # It is plain metadata, so changes update the VM in place (no recreate) and
  # take effect from the next boot.
  metadata = merge(
    {
      ssh-keys       = "${var.ssh_user}:${trimspace(file(var.ssh_public_key_path))}"
      enable-oslogin = "FALSE"
    },
    var.run_hours > 0 || var.run_postscript ? {
      startup-script = templatefile("${path.module}/startup.sh.tftpl", {
        run_hours               = var.run_hours
        run_minutes             = var.run_hours * 60
        update_outline_hostname = var.run_postscript
      })
    } : {}
  )

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

  # Keep the VM running: if it was stopped (e.g. by the run_hours boot script),
  # the next `terraform apply` starts it again, which also restarts the timer.
  desired_status = "RUNNING"

  # Lets Terraform stop the VM briefly for changes that need it
  # (such as changing the machine type).
  allow_stopping_for_update = true

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
