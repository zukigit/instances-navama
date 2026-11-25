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

### Viewing the instances

```bash
terraform output instances
```

This prints each instance's name, zone, internal IP and external IP, grouped by region.

### Destroying everything

```bash
terraform destroy
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
