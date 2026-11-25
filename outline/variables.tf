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

variable "tags" {
  description = "Network tags."
  type        = list(string)
  default     = ["outline"]
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
