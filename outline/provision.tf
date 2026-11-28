# Runs scripts on each instance over SSH. Every line they print is shown in the
# `terraform apply` output, prefixed with the instance it came from.
#
# These live in terraform_data (not inside the instance) so a failed run only
# marks that step for a re-run; the VM itself is not destroyed.
#
# Port 22: every step that connects over SSH first turns the SSH firewall rule
# on itself (so it can never be skipped), and ssh_close turns it off once all
# SSH steps in the apply have finished.
locals {
  manage_ssh_rule = var.close_ssh_after_install
  ssh_rule_cmd    = "gcloud compute firewall-rules update ${google_compute_firewall.outline_ssh.name} --project=${var.project_id} --quiet"
  # Run before connecting; a no-op when close_ssh_after_install = false.
  ssh_open_cmd = local.manage_ssh_rule ? "${local.ssh_rule_cmd} --no-disabled" : "true"
}

# Step 1: install Docker + Outline on each instance.
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

  # Open port 22 before connecting.
  provisioner "local-exec" {
    command = local.ssh_open_cmd
  }

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

# Step 2: Outline access keys (only when access_keys is set). Runs when the VM
# is new or run_hours, run_hours_mode or access_keys changes:
#   reset  -> sync keys with access_keys by name: existing keys keep their ss://
#             link and get usage 0 and the new limit, new names get new keys,
#             keys not listed are deleted; prints all ss:// links
#   append -> keep the keys; at the currently scheduled shutdown (the old timer),
#             reset every key's data usage to 0 (same ss:// links). Runs before
#             shutdown_timer moves that shutdown.
# Re-run with the same values: -replace='terraform_data.access_keys["<region>"]'
resource "terraform_data" "access_keys" {
  for_each = var.run_postscript && length(var.access_keys) > 0 ? google_compute_instance.outline : {}

  triggers_replace = [
    each.value.id,
    var.run_hours,
    var.run_hours_mode,
    jsonencode(var.access_keys),
    filesha256("${path.module}/access-keys.sh"),
  ]

  connection {
    type        = "ssh"
    host        = each.value.network_interface[0].access_config[0].nat_ip
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  depends_on = [terraform_data.outline_install]

  # Open port 22 before connecting.
  provisioner "local-exec" {
    command = local.ssh_open_cmd
  }

  provisioner "file" {
    source      = "${path.module}/access-keys.sh"
    destination = "/tmp/access-keys.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo install -m 0755 /tmp/access-keys.sh /usr/local/sbin/outline-access-keys",
      # New VMs always get fresh keys.
      timecmp(each.value.creation_timestamp, plantimestamp()) >= 0 || var.run_hours_mode == "reset"
      ? "sudo /usr/local/sbin/outline-access-keys reset ${base64encode(jsonencode(var.access_keys))}"
      : "sudo /usr/local/sbin/outline-access-keys append",
    ]
  }
}

# Step 3: apply run_hours to the running VM right away (without a reboot).
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

  # access_keys must read the old shutdown time before this moves it.
  depends_on = [terraform_data.outline_install, terraform_data.access_keys]

  # Open port 22 before connecting.
  provisioner "local-exec" {
    command = local.ssh_open_cmd
  }

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

# Step 4: once all SSH steps have finished, turn the SSH rule off (port 22 closed).
# Runs whenever any SSH step ran. Not reached if one fails, so SSH stays open
# for debugging.
resource "terraform_data" "ssh_close" {
  count = local.manage_ssh_rule ? 1 : 0

  triggers_replace = [
    sort([for run in terraform_data.outline_install : run.id]),
    sort([for run in terraform_data.access_keys : run.id]),
    sort([for run in terraform_data.shutdown_timer : run.id]),
  ]

  provisioner "local-exec" {
    command = "${local.ssh_rule_cmd} --disabled"
  }
}
