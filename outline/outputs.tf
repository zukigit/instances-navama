output "instances" {
  description = "Outline instances, keyed by region."
  value = {
    for region, vm in google_compute_instance.outline : region => {
      name        = vm.name
      zone        = vm.zone
      internal_ip = vm.network_interface[0].network_ip
      external_ip = vm.network_interface[0].access_config[0].nat_ip
    }
  }
}
