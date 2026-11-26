# Installs Docker + Outline on each instance over SSH after it is created.
# Every line the script prints is shown in the `terraform apply` output,
# prefixed with the instance it came from.
#
# This lives in terraform_data (not inside the instance) so a failed install
# only marks this step for a re-run; the VM itself is not destroyed.
locals {
  manage_ssh_rule = var.run_postscript && var.close_ssh_after_install
  ssh_rule_cmd    = "gcloud compute firewall-rules update ${google_compute_firewall.outline_ssh.name} --project=${var.project_id} --quiet"
}

# Step 1: make sure the SSH rule is on before installing.
# Runs again whenever the set of instances or the script changes.
resource "terraform_data" "ssh_open" {
  count = local.manage_ssh_rule ? 1 : 0

  triggers_replace = [
    sort([for vm in google_compute_instance.outline : vm.id]),
    filesha256("${path.module}/postscript.sh"),
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

# Step 3: once every install has finished, turn the SSH rule off (port 22 closed).
# Not reached if an install fails, so SSH stays open for debugging.
resource "terraform_data" "ssh_close" {
  count = local.manage_ssh_rule ? 1 : 0

  triggers_replace = [
    terraform_data.ssh_open[0].id,
    sort([for run in terraform_data.outline_install : run.id]),
  ]

  provisioner "local-exec" {
    command = "${local.ssh_rule_cmd} --disabled"
  }
}
