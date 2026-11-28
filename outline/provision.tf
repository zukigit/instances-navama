# Runs scripts on each instance over SSH. Every line they print is shown in the
# `terraform apply` output, prefixed with the instance it came from.
#
# These live in terraform_data (not inside the instance) so a failed run only
# marks that step for a re-run; the VM itself is not destroyed.
#
# Scripts are uploaded to the SSH user's home, not /tmp: root runs them, and
# other users can't swap a file there before sudo runs it.
#
# Port 22: every step that connects over SSH first turns the SSH firewall rule
# on itself (so it can never be skipped), and ssh_close turns it off once all
# SSH steps in the apply have finished.
locals {
  manage_ssh_rule = var.close_ssh_after_install
  # Access keys need Outline, which run_postscript installs.
  manage_keys  = var.run_postscript && length(var.access_keys) > 0
  ssh_rule_cmd = "gcloud compute firewall-rules update ${google_compute_firewall.outline_ssh.name} --project=${var.project_id} --quiet"
  # Run before connecting; a no-op when close_ssh_after_install = false.
  ssh_open_cmd = local.manage_ssh_rule ? "${local.ssh_rule_cmd} --no-disabled" : "true"
}

# Step 1: install Docker + Outline on each instance.
resource "terraform_data" "outline_install" {
  for_each = var.run_postscript ? google_compute_instance.outline : {}

  # Once per VM: Outline's installer is not safe to run again on a live server
  # (new API secret and certificate, an extra key). postscript.sh also skips
  # the install if Outline is already running. Replace the VM to reinstall.
  triggers_replace = [
    each.value.id,
  ]

  connection {
    type        = "ssh"
    host        = local.external_ip[each.key]
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
    destination = "/home/${var.ssh_user}/postscript.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "bash /home/${var.ssh_user}/postscript.sh ${var.outline_api_port} ${var.outline_keys_port} ${var.outline_installer_commit} ${var.outline_installer_sha256}",
    ]
  }
}

# Step 2: the run_hours period on the running VM (the boot script only runs at
# boot). Runs when the VM is new or run_hours changes; run_hours_mode only says
# how, so switching the mode alone does nothing (MODES.md):
#   reset  -> new period now: usage 0 now, shut down run_hours from now
#   append -> shut down run_hours after the current end; usage resets to 0 at
#             that current end (the old timer)
# Same values again (e.g. append another 24h):
#   terraform apply -replace='terraform_data.shutdown_timer["<region>"]'
resource "terraform_data" "shutdown_timer" {
  for_each = google_compute_instance.outline

  triggers_replace = [
    each.value.id,
    var.run_hours,
    filesha256("${path.module}/shutdown-timer.sh"),
  ]

  connection {
    type        = "ssh"
    host        = local.external_ip[each.key]
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
    source      = "${path.module}/shutdown-timer.sh"
    destination = "/home/${var.ssh_user}/shutdown-timer.sh"
  }

  # The usage resets use the access keys script.
  provisioner "file" {
    source      = "${path.module}/access-keys.sh"
    destination = "/home/${var.ssh_user}/access-keys.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo install -m 0755 /home/${var.ssh_user}/access-keys.sh /usr/local/sbin/outline-access-keys",
      # plantimestamp() lets the script tell whether this apply started the VM
      # (then a new period may already have been started by the boot script).
      "bash /home/${var.ssh_user}/shutdown-timer.sh ${var.run_hours_mode} ${var.run_hours} ${local.manage_keys} ${plantimestamp()}",
    ]
  }
}

# Step 3: Outline access keys (only when access_keys is set). Runs when the VM
# is new or access_keys changes, in any mode. Syncs the keys by name and prints
# every ss:// link; never changes usage (that is the period's job, step 2):
#   existing name -> same key and link, limit from access_keys
#   new name      -> new key and link
#   not listed    -> deleted
resource "terraform_data" "access_keys" {
  for_each = local.manage_keys ? google_compute_instance.outline : {}

  triggers_replace = [
    each.value.id,
    jsonencode(var.access_keys),
    filesha256("${path.module}/access-keys.sh"),
  ]

  connection {
    type        = "ssh"
    host        = local.external_ip[each.key]
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  depends_on = [terraform_data.outline_install, terraform_data.shutdown_timer]

  # Open port 22 before connecting.
  provisioner "local-exec" {
    command = local.ssh_open_cmd
  }

  provisioner "file" {
    source      = "${path.module}/access-keys.sh"
    destination = "/home/${var.ssh_user}/access-keys.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo install -m 0755 /home/${var.ssh_user}/access-keys.sh /usr/local/sbin/outline-access-keys",
      "sudo /usr/local/sbin/outline-access-keys sync ${base64encode(jsonencode(var.access_keys))}",
    ]
  }
}

# Step 3b: when access_keys is empty (keys not managed), cancel any usage
# resets that earlier appends left on the VM, so they don't reset keys you now
# manage yourself. Runs once per VM, and again whenever access_keys is emptied.
resource "terraform_data" "access_keys_off" {
  for_each = local.manage_keys ? {} : google_compute_instance.outline

  triggers_replace = [each.value.id]

  connection {
    type        = "ssh"
    host        = local.external_ip[each.key]
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  depends_on = [terraform_data.outline_install, terraform_data.shutdown_timer]

  # Open port 22 before connecting.
  provisioner "local-exec" {
    command = local.ssh_open_cmd
  }

  provisioner "remote-exec" {
    inline = [
      "if [ -x /usr/local/sbin/outline-access-keys ]; then sudo /usr/local/sbin/outline-access-keys cancel-resets; fi",
      "echo 'access_keys is empty: keys are not managed by Terraform, and no usage resets are pending'",
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
    sort([for run in terraform_data.shutdown_timer : run.id]),
    sort([for run in terraform_data.access_keys : run.id]),
    sort([for run in terraform_data.access_keys_off : run.id]),
  ]

  provisioner "local-exec" {
    command = "${local.ssh_rule_cmd} --disabled"
  }
}

check "access_keys_need_outline" {
  assert {
    condition     = var.run_postscript || length(var.access_keys) == 0
    error_message = "access_keys is ignored because run_postscript = false (Outline is not installed by Terraform)."
  }
}
