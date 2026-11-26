# Installs Docker + Outline on each instance over SSH after it is created.
# Every line the script prints is shown in the `terraform apply` output,
# prefixed with the instance it came from.
#
# This lives in terraform_data (not inside the instance) so a failed install
# only marks this step for a re-run; the VM itself is not destroyed.
locals {
  manage_ssh_rule = var.close_ssh_after_install
  ssh_rule_cmd    = "gcloud compute firewall-rules update ${google_compute_firewall.outline_ssh.name} --project=${var.project_id} --quiet"
}

# Step 1: make sure the SSH rule is on before anything connects over SSH.
# Runs again whenever the instances, the install script or run_hours change.
resource "terraform_data" "ssh_open" {
  count = local.manage_ssh_rule ? 1 : 0

  triggers_replace = [
    sort([for vm in google_compute_instance.outline : vm.id]),
    filesha256("${path.module}/postscript.sh"),
    var.run_hours,
  ]

  provisioner "local-exec" {
    command = "${local.ssh_rule_cmd} --no-disabled"
  }
}

# Step 2: install Docker + Outline on each instance.
resource "terraform_data" "outline_install" {
  for_each = var.run_postscript ? google_compute_instance.outline : {}

  # Re-run when the VM is replaced or the script changes.
  triggers_replace = [
    each.value.id,
    filesha256("${path.module}/postscript.sh"),
  ]

  connection {
    type        = "ssh"
    host        = each.value.network_interface[0].access_config[0].nat_ip
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  depends_on = [terraform_data.ssh_open]

  provisioner "file" {
    source      = "${path.module}/postscript.sh"
    destination = "/tmp/postscript.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "bash /tmp/postscript.sh ${var.outline_api_port} ${var.outline_keys_port}",
    ]
  }
}

# Step 2b: apply run_hours to the running VM right away (without a reboot).
# The boot script only runs at boot, so when run_hours or run_hours_mode changes
# this logs in and updates the scheduled shutdown:
#   reset  -> shut down run_hours from now
#   append -> shut down run_hours after the currently scheduled shutdown
# run_hours = 0 cancels any scheduled shutdown.
# To apply the same value again (e.g. append another 24h), use
#   terraform apply -replace='terraform_data.shutdown_timer["<region>"]'
resource "terraform_data" "shutdown_timer" {
  for_each = google_compute_instance.outline

  triggers_replace = [
    each.value.id,
    var.run_hours,
    var.run_hours_mode,
    filesha256("${path.module}/shutdown-timer.sh"),
  ]

  connection {
    type        = "ssh"
    host        = each.value.network_interface[0].access_config[0].nat_ip
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  depends_on = [terraform_data.ssh_open, terraform_data.outline_install]

  provisioner "file" {
    source      = "${path.module}/shutdown-timer.sh"
    destination = "/tmp/shutdown-timer.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # A VM created in this apply already got run_hours from its boot script,
      # so "append" would double it; use "reset" for new VMs.
      "bash /tmp/shutdown-timer.sh ${timecmp(each.value.creation_timestamp, plantimestamp()) >= 0 ? "reset" : var.run_hours_mode} ${var.run_hours}",
    ]
  }
}

# Step 3: once all SSH steps have finished, turn the SSH rule off (port 22 closed).
# Not reached if one fails, so SSH stays open for debugging.
resource "terraform_data" "ssh_close" {
  count = local.manage_ssh_rule ? 1 : 0

  triggers_replace = [
    terraform_data.ssh_open[0].id,
    sort([for run in terraform_data.outline_install : run.id]),
    sort([for run in terraform_data.shutdown_timer : run.id]),
  ]

  provisioner "local-exec" {
    command = "${local.ssh_rule_cmd} --disabled"
  }
}
