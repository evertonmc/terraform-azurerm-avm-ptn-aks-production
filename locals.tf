locals {
  private_dns_zone_name = try(reverse(split("/", var.private_dns_zone_id))[0], null)
  valid_private_dns_zone_regexs = [
    "private\\.[a-z0-9]+\\.azmk8s\\.io",
    "privatelink\\.[a-z0-9]+\\.azmk8s\\.io",
    "[a-zA-Z0-9\\-]{1,32}\\.private\\.[a-z]+\\.azmk8s\\.io",
    "[a-zA-Z0-9\\-]{1,32}\\.privatelink\\.[a-z]+\\.azmk8s\\.io",
  ]
}

locals {
  default_node_pool_available_zones = setsubtract(local.zones, local.restricted_zones)
  filtered_vms = [
    for sku in data.azapi_resource_list.example.output.value :
    sku if(sku.resourceType == "virtualMachines" && sku.name == var.default_node_pool_vm_sku)
  ]
  restricted_zones = try(local.filtered_vms[0].restrictions[0].restrictionInfo.zones, [])
  zones            = local.filtered_vms[0].locationInfo[0].zones
}

locals {
  filtered_vms_by_node_pool = {
    for pool_name, pool in var.node_pools : pool_name => [
      for sku in data.azapi_resource_list.example.output.value :
      sku if(sku.resourceType == "virtualMachines" && sku.name == pool.vm_size)
    ]
  }
  my_node_pool_zones_by_pool = {
    for pool_name, pool in var.node_pools : pool_name => setsubtract(
      local.filtered_vms_by_node_pool[pool_name][0].locationInfo[0].zones,
      try(local.filtered_vms_by_node_pool[pool_name][0].restrictions[0].restrictionInfo.zones, [])
    )
  }
  zonetagged_node_pools = {
    for pool_name, pool in var.node_pools : pool_name => merge(pool, { zones = local.my_node_pool_zones_by_pool[pool_name] })
  }
}


locals {
  # Create a map of node pool instances for use with for_each.
  # Keys are static (e.g., "poolkey-0") for plan-time evaluation.
  node_pool_instances_for_resource = {
    for item in flatten([
      for np_key, np_config in local.zonetagged_node_pools : [
        for zone_idx, zone_value in (length(np_config.zones) > 0 ? np_config.zones : ["_regional_"]) : {
          _for_each_key = "${np_key}-${zone_idx}"

          # Node pool name for Azure, 12 char limit, zone-suffixed if zonal.
          name_for_azure = substr( (zone_value == "_regional_") ? np_config.name : "${substr(np_config.name, 0, 10)}${zone_value}", 0, 12)

          vm_size              = np_config.vm_size
          orchestrator_version = np_config.orchestrator_version
          max_count            = np_config.max_count
          min_count            = np_config.min_count
          os_sku               = np_config.os_sku
          os_disk_type         = np_config.os_disk_type
          mode                 = np_config.mode
          os_disk_size_gb      = np_config.os_disk_size_gb
          tags                 = np_config.tags
          labels               = np_config.labels
          actual_zones         = (zone_value == "_regional_") ? null : [zone_value]
        }
      ]
    ]) : item._for_each_key => item # Create map: item.key => item
  }
}

locals {
  log_analytics_tables = ["AKSAudit", "AKSAuditAdmin", "AKSControlPlane", "ContainerLogV2"]
}

# Helper locals to make the dynamic block more readable
# There are three attributes here to cater for resources that
# support both user and system MIs, only system MIs, and only user MIs
locals {
  managed_identities = {
    user_assigned = length(var.managed_identities.user_assigned_resource_ids) > 0 ? {
      this = {
        type                       = "UserAssigned"
        user_assigned_resource_ids = var.managed_identities.user_assigned_resource_ids
      }
      } : {
      this = {
        type                       = "UserAssigned"
        user_assigned_resource_ids = azurerm_user_assigned_identity.aks[*].id
      }
    }
  }
}

locals {
  network_resource_group_id = regex("(.*?/resourceGroups/[^/]+)", var.network.node_subnet_id)[0]
}

locals {
  dns_service_ip           = local.has_network_service_cidr ? (try(var.network.dns_service_ip, null) != null ? var.network.dns_service_ip : cidrhost(var.network.service_cidr, 10)) : null
  has_network_service_cidr = try(var.network.service_cidr, null) != null
}
