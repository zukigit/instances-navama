variable "project_id" {
  description = "GCP project ID. Set it in terraform.tfvars (not committed)."
  type        = string
}

variable "regions" {
  description = "Regions to create an Outline instance in (one instance per region)."
  type        = list(string)
  default     = ["us-west1"]

  validation {
    condition     = length(var.regions) > 0 && length(var.regions) == length(distinct(var.regions))
    error_message = "regions must be a non-empty list with no duplicates."
  }
}

variable "instance_name_prefix" {
  description = "Instance names are <prefix>-<region>."
  type        = string
  default     = "outline"
}

variable "machine_type" {
  description = "Machine type."
  type        = string
  default     = "e2-micro"
}

variable "subnetwork" {
  description = "Subnetwork to attach the instance to."
  type        = string
  default     = "default"
}

variable "boot_image" {
  description = "Boot disk image."
  type        = string
  default     = "projects/debian-cloud/global/images/debian-13-trixie-v20261116"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB."
  type        = number
  default     = 10
}

variable "boot_disk_type" {
  description = "Boot disk type."
  type        = string
  default     = "pd-balanced"
}

variable "service_account_email" {
  description = "Service account attached to the instance. Null uses the project's default Compute Engine service account."
  type        = string
  default     = null
}

variable "scopes" {
  description = "OAuth scopes for the service account."
  type        = list(string)
  default = [
    "https://www.googleapis.com/auth/devstorage.read_only",
    "https://www.googleapis.com/auth/logging.write",
    "https://www.googleapis.com/auth/monitoring.write",
    "https://www.googleapis.com/auth/service.management.readonly",
    "https://www.googleapis.com/auth/servicecontrol",
    "https://www.googleapis.com/auth/trace.append",
  ]
}

variable "tag_name" {
  description = "Network tag put on the VMs; the firewall rule targets instances with this tag."
  type        = string
  default     = "outline-nw"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.tag_name))
    error_message = "tag_name must be 1-63 chars of lowercase letters, digits or hyphens, start with a letter and not end with a hyphen (GCP does not allow underscores)."
  }
}

variable "labels" {
  description = "Instance labels."
  type        = map(string)
  default = {
    managed-by = "terraform"
  }
}

variable "network" {
  description = "VPC network the firewall rule applies to."
  type        = string
  default     = "default"
}

variable "firewall_name" {
  description = "Name of the Outline firewall rule."
  type        = string
  default     = "allow-outline"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.firewall_name))
    error_message = "firewall_name must be 1-63 chars of lowercase letters, digits or hyphens, start with a letter and not end with a hyphen."
  }
}

variable "firewall_source_ranges" {
  description = "Source IPv4 ranges allowed to reach the Outline ports."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "outline_tcp_ports" {
  description = "TCP ports to open for Outline."
  type        = list(string)
  default     = ["8443", "9443"]
}

variable "outline_udp_ports" {
  description = "UDP ports to open for Outline."
  type        = list(string)
  default     = ["9443"]
}

variable "run_postscript" {
  description = "Run postscript.sh (Docker + Outline install) on each instance over SSH after it is created."
  type        = bool
  default     = true
}

variable "ssh_user" {
  description = "Linux user Terraform logs in as to run postscript.sh."
  type        = string
  default     = "outline"
}

variable "ssh_public_key_path" {
  description = "Public key added to the instances for ssh_user."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Private key Terraform uses to SSH in. Only the path is used; the key never leaves your machine except for the SSH login."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "ssh_source_ranges" {
  description = "Source IPv4 ranges allowed to SSH to the instances. Narrow this to your own IP (e.g. [\"203.0.113.4/32\"])."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "outline_api_port" {
  description = "Outline management API port (TCP). Must be in outline_tcp_ports."
  type        = number
  default     = 8443
}

variable "outline_keys_port" {
  description = "Outline access keys port (TCP and UDP). Must be in outline_tcp_ports and outline_udp_ports."
  type        = number
  default     = 9443
}

variable "close_ssh_after_install" {
  description = "Turn the SSH firewall rule off after postscript.sh finishes on all instances (needs gcloud). It is turned back on automatically before the next install."
  type        = bool
  default     = true
}

variable "run_hours" {
  description = "Length of a run period in hours: the VM stops at the period end, and access key usage goes to 0 at each period start. A reboot keeps the period. 0 = no limit. See MODES.md."
  type        = number
  default     = 0

  validation {
    condition     = var.run_hours >= 0 && var.run_hours <= 2880 && floor(var.run_hours) == var.run_hours
    error_message = "run_hours must be a whole number from 0 (no limit) to 2880 (120 days)."
  }
}

variable "run_hours_mode" {
  description = "How a run_hours change applies to a running VM: \"reset\" = new period now (usage 0 now); \"append\" = end run_hours after the current end (usage 0 at the current end). Changing only the mode does nothing."
  type        = string
  default     = "reset"

  validation {
    condition     = contains(["reset", "append"], var.run_hours_mode)
    error_message = "run_hours_mode must be \"reset\" or \"append\"."
  }
}

variable "access_keys" {
  description = <<-EOT
    Outline access keys, by name, with an optional data limit in GB (omit or
    null for no limit). Synced by name in any mode: existing keys keep their
    link and usage, new names get new keys, unlisted keys are deleted. Usage
    goes to 0 at each run period start. Empty (default) = keys not managed.
  EOT
  type = map(object({
    data_limit_gb = optional(number)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in values(var.access_keys) : coalesce(k.data_limit_gb, 0) >= 0])
    error_message = "data_limit_gb must be 0 or more."
  }
}
