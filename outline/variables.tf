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
  description = "OAuth scopes for the service account. Only logging and monitoring by default: nothing on the VM needs more, and Outline (host network) could reach the token."
  type        = list(string)
  default = [
    "https://www.googleapis.com/auth/logging.write",
    "https://www.googleapis.com/auth/monitoring.write",
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

  # Used in shell commands and paths on the VM.
  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.ssh_user))
    error_message = "ssh_user must be a plain Linux user name (lowercase letters, digits, _ and -)."
  }
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

variable "outline_installer_commit" {
  description = "Commit of Jigsaw-Code/outline-server whose install_server.sh is used (default: tag server-v1.12.3). Update together with outline_installer_sha256."
  type        = string
  default     = "067d0d47aedac94a3888a127fa6c65f2f53b9987"

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.outline_installer_commit))
    error_message = "outline_installer_commit must be a full 40-character commit SHA."
  }
}

variable "outline_installer_sha256" {
  description = "SHA-256 of install_server.sh at outline_installer_commit; the install stops if the download doesn't match."
  type        = string
  default     = "0144d73391087b1cab6cdf4a353c73b7c0f4c0baada81b08bf2eb89d5b50c16d"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.outline_installer_sha256))
    error_message = "outline_installer_sha256 must be a 64-character hex SHA-256."
  }
}
