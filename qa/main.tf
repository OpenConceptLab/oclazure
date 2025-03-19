terraform {
  backend "azurerm" {
    resource_group_name  = "ocl"
    storage_account_name = "oclqaterraform"
    container_name       = "ocl-qa-terraform"
    key                  = "terraform.tfstate"
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.az_subscription_id
  client_id = var.az_client_id
  client_secret = var.az_client_secret
  tenant_id = var.az_tenant_id
}

locals {
  environment = "qa"
}

resource "azurerm_resource_group" "main" {
  name     = "ocl-${local.environment}"
  location = "westeurope"
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "ocl-${local.environment}-log"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_virtual_network" "main" {
  name                = "ocl-${local.environment}-network"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.1.0.0/16"]
}

resource "azurerm_subnet" "aks" {
  name                 = "ocl-${local.environment}-aks-subnet"
  virtual_network_name = azurerm_virtual_network.main.name
  resource_group_name  = azurerm_resource_group.main.name
  address_prefixes     = ["10.1.1.0/24"]
}

resource "azurerm_subnet" "appgw" {
  name                 = "ocl-${local.environment}-appgw-subnet"
  virtual_network_name = azurerm_virtual_network.main.name
  resource_group_name  = azurerm_resource_group.main.name
  address_prefixes     = ["10.1.2.0/24"]
}

resource "azurerm_container_registry" "main" {
  name                = "ocl${local.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "ocl-${local.environment}-aks"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  private_cluster_enabled = false #TODO: make it private
  dns_prefix = "ocl${local.environment}"
  #private_dns_zone_id = "System" #TODO: uncomment when private

  default_node_pool {
    name       = "default"
    node_count = 3
    vm_size    = "Standard_D11_v2"
    vnet_subnet_id = azurerm_subnet.aks.id
  }

  network_profile {
    network_plugin = "kubenet"
  }

  identity {
    type = "SystemAssigned"
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.main.id
    msi_auth_for_monitoring_enabled = true
  }

  tags = {
    Environment = local.environment
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "main" {
  name                  = "ocl${local.environment}"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = "Standard_DS2_v2"
  node_count            = 1
  vnet_subnet_id        = azurerm_subnet.aks.id
}

resource "azurerm_role_assignment" "network" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.identity[0].principal_id
}

resource "azurerm_role_assignment" "acr" {
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.main.id
  skip_service_principal_aad_check = true
}

resource "azurerm_cdn_frontdoor_profile" "main" {
  name                = "ocl-${local.environment}-frontdoor"
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Premium_AzureFrontDoor"
}

resource "azurerm_cdn_frontdoor_custom_domain" "main" {
  name                     = "ocl-${local.environment}-frontdoor-domain"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  host_name                = "qa.who.openconceptlab.org"

  tls {
    certificate_type    = "ManagedCertificate"
  }
}

resource "random_password" "postgresql" {
  length = 20
}

resource "azurerm_subnet" "db" {
  name                 = "ocl-${local.environment}-db-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.1.3.0/24"]

  #delegation {
  #  name = "fs"
  #  service_delegation {
  #    name = "Microsoft.DBforPostgreSQL/flexibleServers"
  #    actions = [
  #      "Microsoft.Network/virtualNetworks/subnets/join/action",
  #    ]
  #  }
  #}
}

resource "azurerm_private_dns_zone" "db" {
  name                = "${local.environment}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "db" {
  name                  = "ocl-${local.environment}-db-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.db.name
  virtual_network_id    = azurerm_virtual_network.main.id
  resource_group_name   = azurerm_resource_group.main.name
}

resource "azurerm_private_endpoint" "db" {
  name                = "ocl-${local.environment}-db-private-endpoint"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.db.id

  private_service_connection {
    name = "ocl-${local.environment}-db-connection"
    private_connection_resource_id = azurerm_postgresql_flexible_server.main.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "ocl-${local.environment}-db-dns-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.db.id]
  }
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                          = "ocl-${local.environment}-db"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = "14"
  #delegated_subnet_id           = azurerm_subnet.db.id
  #private_dns_zone_id           = azurerm_private_dns_zone.db.id
  public_network_access_enabled = false
  administrator_login           = "ocladmin"
  administrator_password        = random_password.postgresql.result
  zone                          = "1"
  storage_mb                    = 32768
  sku_name                      = "GP_Standard_D2s_v3"
  backup_retention_days         = 7

  #depends_on = [azurerm_private_dns_zone_virtual_network_link.db]
}

resource "azurerm_postgresql_flexible_server_database" "ocl" {
  name      = "ocl-db"
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"

  # prevent the possibility of accidental data loss
  lifecycle {
    #prevent_destroy = true
  }
}

resource "azurerm_postgresql_flexible_server_database" "keycloak" {
  name      = "ocl-keycloak"
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"

  # prevent the possibility of accidental data loss
  lifecycle {
    #prevent_destroy = true
  }
}

resource "azurerm_redis_cache" "main" {
  name                = "ocl-${local.environment}-redis"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  capacity            = 2
  family              = "C"
  sku_name            = "Basic"
  public_network_access_enabled = false
  non_ssl_port_enabled = true
  minimum_tls_version = "1.2"
  redis_version = "6"

  redis_configuration {

  }
}

resource "azurerm_subnet" "redis" {
  name                 = "ocl-${local.environment}-redis-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.1.4.0/24"]
}

resource "azurerm_private_dns_zone" "redis" {
  name                = "${local.environment}.redis.cache.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = "ocl-${local.environment}-redis-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.redis.name
  virtual_network_id    = azurerm_virtual_network.main.id
  resource_group_name   = azurerm_resource_group.main.name
}

resource "azurerm_private_endpoint" "redis" {
  name                = "ocl-${local.environment}-redis-private-endpoint"
  location            = azurerm_redis_cache.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.redis.id

  private_dns_zone_group {
    name                 = "ocl-${local.environment}-redis-dns-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }

  private_service_connection {
    name                           = "ocl-${local.environment}-redis-connection"
    private_connection_resource_id = azurerm_redis_cache.main.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }
}

resource "azurerm_storage_account" "main" {
  name                     = "ocl${local.environment}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "exports" {
  name                  = "ocl-${local.environment}-exports"
  storage_account_id = azurerm_storage_account.main.id
  container_access_type = "blob"
}

resource "azurerm_user_assigned_identity" "exports" {
  name                = "ocl-${local.environment}-exports"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_role_assignment" "exports" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.exports.principal_id
}

provider "kubernetes" {
  host = azurerm_kubernetes_cluster.main.kube_config.0.host

  client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host = azurerm_kubernetes_cluster.main.kube_config.0.host

    client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.cluster_ca_certificate)
  }
}

resource "helm_release" "elastic" {
  name       = "elastic-operator"
  repository = "https://helm.elastic.co"
  chart      = "eck-operator"
  namespace         = "elastic-system"
  create_namespace  = true
  force_update = true
  dependency_update = true #helm repo update command
}

resource "time_sleep" "wait_30_seconds" {
  depends_on = [helm_release.elastic]

  create_duration = "30s"
}


#resource "kubernetes_manifest" "elasticsearch" {
#  manifest = yamldecode(file("elasticsearch.yaml"))
#
#  provisioner "local-exec" {
#    command = "sleep 60"
#  }
#
#  depends_on = [helm_release.elastic, time_sleep.wait_30_seconds]
#}

#data "kubernetes_secret" "es_password" {
#  metadata {
#    name = "elasticsearch-es-elastic-user"
#    namespace = "elastic-system"
#  }

#  depends_on = [
#    kubernetes_manifest.elasticsearch
#  ]
#}