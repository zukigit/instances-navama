# Outline instances on GCP

Terraform that creates one Outline VM per region, plus a firewall rule that opens the Outline ports on every VM with the network tag `tag_name` (default `outline-nw`).

For what each mode (`reset`, `append`, boot, IP change) does step by step, see [MODES.md](MODES.md).

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

### Run periods (stopping instances after a set time)

Set `run_hours` to have each VM stop after that many hours (default `0`, no limit). The time between the start of the period and the shutdown is a **period**. Keep `run_hours` and `run_hours_mode` in `terraform.tfvars`, not only in `-var` (see the warning below):

```hcl
run_hours      = 720       # 30 days
run_hours_mode = "reset"   # or "append"
```

Terraform acts on a running VM when `run_hours` changes. `run_hours_mode` says how; changing only the mode does nothing.

| Mode | `run_hours = 24` means |
|---|---|
| `reset` (default) | New period now: stop 24 hours from now, and every access key's usage goes to 0 now |
| `append` | Stop 24 hours after the current period's end. Usage stays as it is until that old end, then goes to 0 |
| `run_hours = 0` | No shutdown (cancels the pending one) |

To run it again with the same values (for example, append another 24 hours, or start a new period now), force it:

```bash
terraform apply -replace='terraform_data.shutdown_timer["us-west1"]'
```

The period's end is saved on the VM, so **a reboot doesn't change it**. At every boot, the boot script either continues the period (its end is still ahead) or, if the end passed while the VM was off, starts a new `run_hours` period with usage reset to 0. So after the timer has stopped a VM, a plain `terraform apply` starts it again in a new period. `desired_status = "RUNNING"` makes every apply start a stopped VM.

> **Warning:** a plain `terraform apply` uses `terraform.tfvars`. If you ran `apply -var='run_hours=24'` and `terraform.tfvars` says `720`, the next plain apply sees a change back to `720` and runs again, in reset mode if that's the mode in `terraform.tfvars`, resetting everyone's usage now.

The shutdown runs inside the VM, so someone logged in could cancel it with `sudo shutdown -c`. Stopping keeps the disk, so Outline stays installed, but the VM may get a new external IP, which changes every key's link (see [After a restart](#after-a-restart-new-ip)). For the exact logic in every case, see [MODES.md](MODES.md).

### Access keys (VPN keys)

List the keys in `access_keys` and Terraform creates them through Outline's management API, with a data limit each, and prints the `ss://` links in the apply output. They are not saved anywhere on your machine.

```hcl
access_keys = {
  alice = { data_limit_gb = 200 }
  bob   = {}                      # no limit
}
```

```
terraform_data.access_keys["us-west1"] (remote-exec): ===== Outline access keys =====
terraform_data.access_keys["us-west1"] (remote-exec): alice (200 GB): ss://...
terraform_data.access_keys["us-west1"] (remote-exec): dave (50 GB, NEW link): ss://...
```

The step runs when the VM is new or `access_keys` changes, in either mode, and matches keys by name:

| On the server | Result |
|---|---|
| Name in `access_keys`, key exists | Same key and link; the limit is set from `access_keys`; usage unchanged |
| Name in `access_keys`, no key | New key and link (`NEW link`) |
| Key not in `access_keys` (including ones made in Manager) | Deleted |

Usage is reset by the run periods, not by this step: at the start of each period, every key starts again at 0. Outline has no "reset usage" call and counts usage per key ID, so each key is deleted and created again with the same name, password, port and limit. The `ss://` link only holds the password, host and port, so **users keep the link they have**. Connected users drop for a moment, and Manager loses the usage history from before the reset. Usage resets for `append` are systemd timers on the VM: `systemctl list-timers 'outline-usage-reset-*'`.

Links also contain the server's IP, so when the IP changes users need their new link anyway. To give one user a new link (for example, if theirs leaked), rename their entry in `access_keys`. With `access_keys` empty (default), Terraform does not touch the keys or reset their usage; emptying it later also cancels usage resets that are still pending. `access_keys` needs `run_postscript = true`. If a usage reset can't create a key again, it retries from a backup. If that keeps failing, at most one key is missing until `sudo outline-access-keys restore` on the VM or the next keys sync brings it back with the same link.

### After a restart (new IP)

The external IP is ephemeral, so it changes every time a VM is stopped and started. A boot script (`startup.sh.tftpl`, set as the VM's `startup-script` metadata) handles Outline's side automatically at every boot:

- reads the VM's current external IP from the metadata server
- if it differs from the IP in `/opt/outline/access.txt`, tells Outline the new IP (`PUT /server/hostname-for-access-keys` on the local API) and updates `apiUrl` in `access.txt`

It works for any restart: `terraform apply`, `gcloud compute instances start`, or the Console. Its log is in `sudo journalctl -u google-startup-scripts` on the VM. What is still up to you:

1. In Outline Manager, remove the server and add it again with the `apiUrl` using the new IP (same secret and `certSha256`; `terraform output instances` shows the IP).
2. Share the access keys again: Manager now shows them with the new IP, but keys already handed out still point to the old one.

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

The installer comes from a pinned commit and is checked against its SHA-256 (see [Notes](#notes)). This needs an SSH key pair, `~/.ssh/id_ed25519` by default (`ssh-keygen -t ed25519` if you don't have one). If the install fails, the VM is kept and the next `apply` runs the script again. The install runs **once per VM**: editing `postscript.sh` doesn't re-run it on existing VMs, and the script skips the install if Outline is already running. That's because Outline's installer isn't safe to run twice on a live server: it would make a new API secret and certificate, so Manager would have to add the server again, and it would add a key. To reinstall, replace the VM (`terraform apply -replace='google_compute_instance.outline["<region>"]'`), which gives new keys and links. Set `run_postscript = false` to skip the install.

Outline's installer creates one unnamed access key on every new server. With `access_keys` set, the keys step deletes it, because it isn't listed.

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
| `scopes` | logging and monitoring write only | OAuth scopes for the service account; see Notes |
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
| `run_hours` | `0` (no limit) | Length of a run period; the VM stops at its end, and `apply` starts it again in a new period |
| `run_hours_mode` | `reset` | How a `run_hours` change applies: `reset` starts a new period now (usage 0); `append` extends the current one (usage 0 at its old end) |
| `access_keys` | `{}` (keys not managed) | Outline keys, `name = { data_limit_gb = N }`; see [Access keys](#access-keys-vpn-keys) |
| `ssh_source_ranges` | `["0.0.0.0/0"]` | Sources allowed to SSH in; narrow to your IP |
| `outline_api_port` | `8443` | Outline management API port (TCP) |
| `outline_keys_port` | `9443` | Outline access keys port (TCP and UDP) |
| `outline_installer_commit` | commit of `server-v1.12.3` | outline-server commit whose `install_server.sh` is used |
| `outline_installer_sha256` | SHA-256 of that file | The install stops if the downloaded installer doesn't match |

You can override any of these with `-var` or in `terraform.tfvars`. Never commit `terraform.tfvars`; put shareable examples in `terraform.tfvars.example`.

## Notes

- **Ports:** `outline_api_port` and `outline_keys_port` are used when Outline is installed, so they only take effect on a new VM. Changing them later does nothing to an existing server; replace the VM (`-replace='google_compute_instance.outline["<region>"]'`) to use new ports, which gives new keys and links. The firewall ports (`outline_tcp_ports`, `outline_udp_ports`) must include them; `plan` stops with an error if they don't.
- **Service account scopes:** only `logging.write` and `monitoring.write` by default. The gcloud defaults also include read access to every Cloud Storage bucket in the project, and Outline runs with host networking, so it could read the VM's token. Nothing in this setup needs more. Changing `scopes` stops and restarts the VM once (`allow_stopping_for_update`).
- **Pinned installer:** `postscript.sh` downloads Outline's `install_server.sh` from a fixed commit and checks its SHA-256, so a change upstream can't run as root on your VMs. The Outline server image itself (`shadowbox:stable`) is still updated automatically by the watchtower container the installer sets up. To move to a newer installer, pick a release at github.com/Jigsaw-Code/outline-server/releases, then set both values:
  ```bash
  TAG=server-v1.12.3   # the release you want
  # the commit the tag points to (the "^{}" line, if the tag is annotated)
COMMIT=$(git ls-remote https://github.com/Jigsaw-Code/outline-server "refs/tags/$TAG" "refs/tags/$TAG^{}" | sort -k2 -r | head -n1 | cut -f1)
  curl -fsSL "https://raw.githubusercontent.com/Jigsaw-Code/outline-server/$COMMIT/src/server_manager/install_scripts/install_server.sh" | sha256sum
  # outline_installer_commit = "$COMMIT", outline_installer_sha256 = <the hash above>
  ```
  This only affects new VMs (the installer runs once per VM).
- **Cost:** the free e2-micro only applies in `us-west1`, `us-central1` and `us-east1`. Instances in any other region are billed.
- **External IPs are temporary.** An instance's IP can change when it is stopped and started, so any Outline access keys that use that IP stop working. Reserve a static address if you need it to stay the same.
- **State:** Terraform keeps its state in a local `terraform.tfstate` file, which is not committed to git. Keep that file somewhere safe; without it, Terraform can no longer manage the instances it created.
- **Existing resources:** if a VM named `outline-<region>` or the firewall rule (`firewall_name`, default `allow-outline`) already exists, `apply` fails. Import it into Terraform first:
  ```bash
  terraform import 'google_compute_instance.outline["us-west1"]' projects/<project>/zones/<zone>/instances/outline-us-west1
  terraform import google_compute_firewall.outline <firewall_name>
  ```
