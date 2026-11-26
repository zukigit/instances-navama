# Outline instances on GCP

Terraform that creates one Outline VM per region, plus a firewall rule that opens the Outline ports on every VM with the network tag `tag_name` (default `outline-nw`).

## What gets created

- **One VM per region** in `regions`, named `outline-<region>` (for example `outline-us-west1`). Each VM is:
  - `e2-micro`, Debian 13 (trixie), 10 GB `pd-balanced` boot disk
  - on the `default` network, with a temporary (ephemeral) external IP on the Standard tier
  - Shielded VM with vTPM and integrity monitoring on, secure boot off
  - tagged with `tag_name` (default `outline-nw`)
  - placed in the first available zone of its region
- **One firewall rule**, named `firewall_name` (default `allow-outline`): incoming traffic from `0.0.0.0/0` to instances tagged with `tag_name`, priority 1000.
  - TCP: `8443`, `9443`
  - UDP: `9443`
- **An SSH firewall rule**, `<firewall_name>-ssh`: TCP 22 from `ssh_source_ranges` to the same tag, so Terraform can run `postscript.sh`. Turned off after the install by default.

## Requirements

- Terraform 1.5 or later
- The `gcloud` CLI, signed in with access to the project:
  ```bash
  gcloud auth application-default login
  ```
- The Compute Engine API enabled on the project

## Usage

Set your project first. `terraform.tfvars` is in `.gitignore`, so it stays on your machine:

```bash
cd outline
cp terraform.tfvars.example terraform.tfvars
# set project_id (and regions) in terraform.tfvars
```

```bash
terraform init
terraform plan
terraform apply -auto-approve
```

With only `project_id` set, this creates a single instance in `us-west1`.

### Choosing regions

From the command line:

```bash
terraform apply -var='regions=["us-west1","europe-west1","asia-southeast1"]'
```

Or set `regions` in `terraform.tfvars`, which Terraform reads automatically.

Every region in the list gets its own instance. If you edit the list later, the next `apply` creates instances for regions you added and **destroys** instances for regions you removed.

### Stopping instances after a set time

Set `run_hours` to have GCP stop each VM after it has been running that long (default `0`, no limit):

```bash
terraform apply -var='run_hours=12'
```

This adds a small boot script to the VM's metadata that runs `shutdown -h +<minutes>` at every boot, so the timer starts each time the VM boots. Changing `run_hours` updates the VM in place (it is not recreated). On a running VM, Terraform also logs in over SSH and updates the scheduled shutdown right away. `run_hours_mode` picks how:

| Mode | `run_hours=24` means |
|---|---|
| `reset` (default) | Shut down exactly 24 hours from now, whatever was scheduled before |
| `append` | Add 24 hours to the time currently left (from now if nothing is scheduled) |

```bash
terraform apply -var='run_hours=24'                              # reset: stop 24h from now
terraform apply -var='run_hours=24' -var='run_hours_mode=append' # add 24h to the time left
terraform apply -var='run_hours=0'                               # cancel the scheduled shutdown
```

Terraform only acts when `run_hours` or `run_hours_mode` changes. To run it again with the same values (for example, append another 24 hours), force it:

```bash
terraform apply -var='run_hours=24' -var='run_hours_mode=append' \
  -replace='terraform_data.shutdown_timer["us-west1"]'
```

A VM created in the same `apply` always uses `reset`, since its boot script has just scheduled `run_hours`. After any reboot, the boot script starts a fresh `run_hours` countdown, and earlier appended time does not carry over.

The shutdown runs inside the VM, so someone logged in could cancel it with `sudo shutdown -c`. The VMs have `desired_status = "RUNNING"`, so after a VM is stopped, the next `terraform apply` starts it again with a fresh timer. Stopping keeps the disk, so Outline stays installed, but the VM gets a new external IP unless you reserve a static one, so existing access keys stop working.

### Viewing the instances

```bash
terraform output instances
```

This prints each instance's name, zone, internal IP and external IP, grouped by region.

### Destroying everything

```bash
terraform destroy
```

### Installing Outline

After each VM is created, Terraform connects over SSH and runs `postscript.sh`, which installs Docker and Outline server. Every line it prints shows up in the `terraform apply` output, prefixed with the instance it came from:

```
terraform_data.outline_install["us-west1"] (remote-exec): ...
```

At the end it prints the Outline Manager config (`apiUrl` and `certSha256`) from `/opt/outline/access.txt`. Copy it into Outline Manager. To also keep the whole log in a file:

```bash
terraform apply 2>&1 | tee apply.log
```

This needs an SSH key pair, `~/.ssh/id_ed25519` by default (`ssh-keygen -t ed25519` if you don't have one). If the install fails, the VM is kept and the next `apply` runs the script again. Editing `postscript.sh` also makes the next `apply` re-run it on every instance. Set `run_postscript = false` to skip the install.

Port 22 is only open while the install runs. Before installing, Terraform turns the `<firewall_name>-ssh` rule on; once every instance has finished, it turns the rule off again with `gcloud`, so `gcloud` must be installed and signed in (`gcloud auth login`). If an install fails, the rule stays on so you can SSH in and debug; the next successful `apply` turns it off. Set `close_ssh_after_install = false` to keep port 22 open. This only closes port 22 if no other rule opens it: new GCP projects come with `default-allow-ssh` (TCP 22 from anywhere, all VMs). Disable it with `gcloud compute firewall-rules update default-allow-ssh --disabled`, but check that no other VM in the project needs it first. To open it by hand later:

```bash
gcloud compute firewall-rules update allow-outline-ssh --no-disabled   # open
gcloud compute firewall-rules update allow-outline-ssh --disabled      # close
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `project_id` | *(required)* | GCP project; set it in `terraform.tfvars` |
| `regions` | `["us-west1"]` | Regions to create instances in, one instance each |
| `instance_name_prefix` | `outline` | Instances are named `<prefix>-<region>` |
| `machine_type` | `e2-micro` | Machine type |
| `boot_image` | `debian-13-trixie-v20261116` | Boot disk image |
| `boot_disk_size_gb` | `10` | Boot disk size in GB |
| `boot_disk_type` | `pd-balanced` | Boot disk type |
| `network` | `default` | VPC network for the firewall rule |
| `subnetwork` | `default` | Subnet name, looked up in each region |
| `service_account_email` | `null` (project's default compute SA) | Service account attached to the VMs |
| `scopes` | gcloud default scopes | OAuth scopes for the service account |
| `tag_name` | `outline-nw` | Network tag on the VMs; the firewall rule targets this tag |
| `labels` | `{ managed-by = "terraform" }` | Instance labels |
| `firewall_name` | `allow-outline` | Name of the firewall rule |
| `firewall_source_ranges` | `["0.0.0.0/0"]` | Source addresses allowed through the firewall |
| `outline_tcp_ports` | `["8443", "9443"]` | TCP ports to open |
| `outline_udp_ports` | `["9443"]` | UDP ports to open |
| `run_postscript` | `true` | Run `postscript.sh` on each instance after it is created |
| `ssh_user` | `outline` | User Terraform logs in as |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | Public key added to the VMs |
| `ssh_private_key_path` | `~/.ssh/id_ed25519` | Private key Terraform uses to log in |
| `close_ssh_after_install` | `true` | Turn the SSH rule off after the install finishes |
| `run_hours` | `0` (no limit) | Stop each VM after this many hours of running; `apply` starts it again |
| `run_hours_mode` | `reset` | `reset`: stop `run_hours` from now; `append`: add `run_hours` to the time left |
| `ssh_source_ranges` | `["0.0.0.0/0"]` | Sources allowed to SSH in; narrow to your IP |
| `outline_api_port` | `8443` | Outline management API port (TCP) |
| `outline_keys_port` | `9443` | Outline access keys port (TCP and UDP) |

You can override any of these with `-var` or in `terraform.tfvars`. Never commit `terraform.tfvars`; put shareable examples in `terraform.tfvars.example`.

## Notes

- **Cost:** the free e2-micro only applies in `us-west1`, `us-central1` and `us-east1`. Instances in any other region are billed.
- **External IPs are temporary.** An instance's IP can change when it is stopped and started, so any Outline access keys that use that IP stop working. Reserve a static address if you need it to stay the same.
- **State:** Terraform keeps its state in a local `terraform.tfstate` file, which is not committed to git. Keep that file somewhere safe; without it, Terraform can no longer manage the instances it created.
- **Existing resources:** if a VM named `outline-<region>` or the firewall rule (`firewall_name`, default `allow-outline`) already exists, `apply` fails. Import it into Terraform first:
  ```bash
  terraform import 'google_compute_instance.outline["us-west1"]' projects/<project>/zones/<zone>/instances/outline-us-west1
  terraform import google_compute_firewall.outline <firewall_name>
  ```
