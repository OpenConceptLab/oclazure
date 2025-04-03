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
  domain = "who.openconceptlab.org"

  api_config = merge(var.api_config, {
    ENVIRONMENT = "test.who"
    API_BASE_URL = "https://api.${local.environment}.${local.domain}"
    API_HOST = "localhost"
    API_PORT = "8000"
    API_INTERNAL_BASE_URL = "http://localhost:8000"

    DB_HOST = "ocl-qa-db.${azurerm_private_dns_zone.db.name}"
    DB_PORT = "5432"
    DB_USER = azurerm_postgresql_flexible_server.main.administrator_login
    DB_PASSWORD = azurerm_postgresql_flexible_server.main.administrator_password
    DB_NAME = azurerm_postgresql_flexible_server_database.ocl.name

    ES_HOSTS = "elasticsearch-es-http.elastic-system:9200"
    ES_SCHEME = "https"
    ES_VERIFY_CERTS = "false"
    ES_USER = "elastic"
    ES_PASSWORD = data.kubernetes_secret.es_password.data["elastic"]

    REDIS_HOST = "ocl-qa-redis.${azurerm_private_dns_zone.redis.name}"
    REDIS_PORT = azurerm_redis_cache.main.port
    REDIS_PASSWORD = azurerm_redis_cache.main.primary_access_key

    FLOWER_HOST = "flower"
    FLOWER_PORT = "80"

    IMPORT_DEMO_DATA = "true"

    EMAIL_HOST = "smtp.gmail.com"
    EMAIL_PORT = "587"
    EMAIL_USE_TLS = "true"

    EXPORT_SERVICE = "core.services.storages.cloud.azure.BlobStorage"

    AZURE_STORAGE_ACCOUNT_NAME = azurerm_storage_account.main.name
    AZURE_STORAGE_CONTAINER_NAME = azurerm_storage_container.exports.name
    AZURE_STORAGE_CONNECTION_STRING = "oclqa.${azurerm_private_dns_zone.storage.name}"

    OIDC_SERVER_URL = "https://sso.${local.environment}.${local.domain}"
    OIDC_REALM = "ocl"
    FHIR_SUBDOMAIN = "fhir"
  })


  web_config = merge(var.web_config, {
    LOGIN_REDIRECT_URL = "https://${local.environment}.${local.domain}/"
    LOGOUT_REDIRECT_URL = "https://${local.environment}.${local.domain}/"
    API_URL = "https://api.${local.environment}.${local.domain}"
  })
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
  private_link_service_network_policies_enabled = false
}

resource "azurerm_subnet" "endpoint" {
  name                 = "ocl-${local.environment}-endpoint-subnet"
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

    upgrade_settings {
      drain_timeout_in_minutes      = 0
      max_surge                     = "10%"
      node_soak_duration_in_minutes = 0
    }
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
  name                = "privatelink.postgres.database.azure.com"
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
  subnet_id           = azurerm_subnet.endpoint.id

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

resource "azurerm_postgresql_flexible_server_configuration" "main" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "BTREE_GIN,PG_TRGM,BTREE_GIST"
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
  name                = "privatelink.redis.cache.windows.net"
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
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.endpoint.id

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

resource "azurerm_private_dns_zone" "storage" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage" {
  name                  = "ocl-${local.environment}-storage-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.storage.name
  virtual_network_id    = azurerm_virtual_network.main.id
  resource_group_name   = azurerm_resource_group.main.name
}

resource "azurerm_private_endpoint" "storage" {
  name                = "ocl-${local.environment}-storage-endpoint"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.endpoint.id

  private_service_connection {
    name                           = "ocl-${local.environment}-storage-connection"
    private_connection_resource_id = azurerm_storage_account.main.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "ocl-${local.environment}-storage-dns-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage.id]
  }
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

provider "kubectl" {
  host                   = azurerm_kubernetes_cluster.main.kube_config.0.host
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.cluster_ca_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.client_key)
  client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.client_certificate)
  load_config_file       = false
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

resource "time_sleep" "wait_for_elastic_operator" {
  depends_on = [helm_release.elastic]

  create_duration = "30s"
}

resource "kubectl_manifest" "elasticsearch" {
  yaml_body = file("elasticsearch.yaml")

  depends_on = [helm_release.elastic, time_sleep.wait_for_elastic_operator]
}

resource "time_sleep" "wait_for_elasticsearch" {
  depends_on = [kubectl_manifest.elasticsearch]

  create_duration = "30s"
}

data "kubernetes_secret" "es_password" {
  metadata {
    name = "elasticsearch-es-elastic-user"
    namespace = "elastic-system"
  }

  depends_on = [
    time_sleep.wait_for_elasticsearch
  ]
}

# Internal ingress-nginx for Azure Front Door support
resource "helm_release" "ingress" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace         = "ingress-nginx"
  create_namespace  = true
  force_update = true
  dependency_update = true #helm repo update command
  set {
    name = "controller.watchIngressWithoutClass"
    value = "true"
  }
  set {
    name = "controller.ingressClassResource.default"
    value = "true"
  }
  set {
    name  = "controller.replicaCount"
    value = "2"
  }
  set {
    name = "controller.service.loadBalancerIP"
    value = "10.1.1.128" # Needs to be an unused IP from AKS subnet
  }
  set {
    name="controller.service.externalTrafficPolicy"
    value = "Local"
  }
  set {
    name = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-internal"
    value = "true"
  }
  set {
    name = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-pls-create"
    value = "true"
  }
//  set {
//    name = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-pls-auto-approval"
//    value = var.az_subscription_id
//  }

  set {
    name = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-pls-name"
    value = "ocl-${local.environment}-ingress-pls"
  }

  set {
    name = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-pls-resource-group"
    value = azurerm_resource_group.main.name
  }
}

data "azurerm_private_link_service" "ingress" {
  name = "ocl-${local.environment}-ingress-pls"
  resource_group_name = azurerm_resource_group.main.name

  depends_on = [helm_release.ingress]
}

resource "azurerm_cdn_frontdoor_profile" "main" {
  name                = "ocl-${local.environment}-frontdoor"
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Premium_AzureFrontDoor"
}

resource "azurerm_cdn_frontdoor_custom_domain" "main" {
  name                     = "ocl-${local.environment}-frontdoor-domain"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  host_name                = "${local.environment}.${local.domain}"

  tls {
    certificate_type    = "ManagedCertificate"
  }
}

resource "azurerm_cdn_frontdoor_custom_domain" "sso" {
  name                     = "ocl-${local.environment}-sso-frontdoor-domain"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  host_name                = "sso.${local.environment}.${local.domain}"

  tls {
    certificate_type    = "ManagedCertificate"
  }
}

resource "azurerm_cdn_frontdoor_custom_domain" "api" {
  name                     = "ocl-${local.environment}-api-frontdoor-domain"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  host_name                = "api.${local.environment}.${local.domain}"

  tls {
    certificate_type    = "ManagedCertificate"
  }
}

resource "azurerm_cdn_frontdoor_custom_domain" "fhir" {
  name                     = "ocl-${local.environment}-fhir-frontdoor-domain"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  host_name                = "fhir.${local.environment}.${local.domain}"

  tls {
    certificate_type    = "ManagedCertificate"
  }
}

resource "azurerm_cdn_frontdoor_custom_domain" "flower" {
  name                     = "ocl-${local.environment}-flower-frontdoor-domain"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  host_name                = "flower.${local.environment}.${local.domain}"

  tls {
    certificate_type    = "ManagedCertificate"
  }
}

resource "azurerm_cdn_frontdoor_origin_group" "main" {
  name                     = "ocl-${local.environment}-frontdoor-origin-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  load_balancing {}
}

resource "azurerm_cdn_frontdoor_origin" "main" {
  name                          = "ocl-${local.environment}-frontdoor-origin"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main.id
  enabled                       = true

  certificate_name_check_enabled = true
  host_name                      = data.azurerm_private_link_service.ingress.alias
  priority                       = 1
  weight                         = 500

  private_link {
    request_message        = "Request access for Private Link Origin CDN Frontdoor"
    location               = azurerm_resource_group.main.location
    private_link_target_id = data.azurerm_private_link_service.ingress.id
  }
}

resource "azurerm_cdn_frontdoor_endpoint" "main" {
  name                     = "ocl-${local.environment}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  tags = {
    ENV = local.environment
  }
}

resource "azurerm_cdn_frontdoor_route" "main" {
  name                          = "ocl-${local.environment}-route"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.main.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.main.id]
  enabled                       = true

  forwarding_protocol    = "HttpOnly"
  https_redirect_enabled = true
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]

  cdn_frontdoor_custom_domain_ids = [azurerm_cdn_frontdoor_custom_domain.main.id,
    azurerm_cdn_frontdoor_custom_domain.sso.id, azurerm_cdn_frontdoor_custom_domain.api.id,
    azurerm_cdn_frontdoor_custom_domain.fhir.id, azurerm_cdn_frontdoor_custom_domain.flower.id]
  link_to_default_domain          = false
}

# Keycloak deployment
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


resource "helm_release" "keycloak" {
  name              = "keycloak"
  repository        = "oci://registry-1.docker.io/bitnamicharts/"
  chart             = "keycloak"
  namespace         = "keycloak"
  create_namespace  = true
  force_update      = true
  dependency_update = true #helm repo update command
  set {
    name  = "replicaCount"
    value = "2"
  }
  set {
    name = "postgresql.enabled"
    value = "false"
  }
  set {
    name = "externalDatabase.host"
    value = "ocl-qa-db.privatelink.postgres.database.azure.com"
  }
  set {
    name = "externalDatabase.user"
    value = "ocladmin"
  }
  set {
    name = "proxy"
    value = "edge"
  }

  set {
    name = "externalDatabase.password"
    value = random_password.postgresql.result
  }

  set {
    name = "externalDatabase.database"
    value = "ocl-keycloak"
  }

  set {
    name = "externalDatabase.port"
    value = "5432"
  }

  set {
    name = "ingress.enabled"
    value = "true"
  }

  set {
    name = "ingress.hostname"
    value = "sso.qa.who.openconceptlab.org"
  }
}

resource "kubernetes_namespace" "ocl" {
  metadata {
    annotations = {
      name = "ocl"
    }

    name = "ocl"
  }
}

resource "kubernetes_deployment" "oclapi2" {
  metadata {
    name = "oclapi2"
    labels = {
      App = "oclapi2"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "oclapi2"
      }
    }
    template {
      metadata {
        labels = {
          App = "oclapi2"
        }
      }
      spec {
        subdomain = "api"
        container {
          image = "docker.io/openconceptlab/oclapi2:qa"
          name  = "oclapi2"
          image_pull_policy = "Always"

          port {
            container_port = 8000
          }

          env {
            name = "PYTHONUNBUFFERED"
            value = "0"
          }

          dynamic "env" {
            for_each = local.api_config
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = "0.2"
              memory = "512Mi"
            }
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "oclapi2" {
  metadata {
    name = "oclapi2"
  }
  spec {
    selector = {
      App = kubernetes_deployment.oclapi2.spec.0.template.0.metadata[0].labels.App
    }
    port {
      port        = 80
      target_port = 8000
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "oclapi" {
  metadata {
    name = "oclapi"
    namespace = kubernetes_namespace.ocl.metadata.0.name
  }
  spec {
    rule {
      host = "api.${local.environment}.${local.domain}"
      http {
        path {
          path = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.oclapi2.metadata.0.name
              port {
                number = kubernetes_service.oclapi2.spec.0.port.0.port
              }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.ingress]
}

resource "kubernetes_deployment" "oclfhir" {
  metadata {
    name = "oclfhir"
    labels = {
      App = "oclfhir"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "oclfhir"
      }
    }
    template {
      metadata {
        labels = {
          App = "oclfhir"
        }
      }
      spec {
        subdomain = "fhir"
        container {
          image = "docker.io/openconceptlab/oclapi2:qa"
          name  = "oclapi2"
          image_pull_policy = "Always"

          port {
            container_port = 8000
          }

          env {
            name = "PYTHONUNBUFFERED"
            value = "0"
          }

          dynamic "env" {
            for_each = local.api_config
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = "0.2"
              memory = "512Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/version"
              port = 8000
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "oclfhir" {
  metadata {
    name = "oclfhir"
    annotations = {
    }
  }
  spec {
    selector = {
      App = kubernetes_deployment.oclfhir.spec.0.template.0.metadata[0].labels.App
    }
    port {
      port        = 80
      target_port = 8000
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "oclfhir" {
  metadata {
    name = "oclfhir"
    namespace = kubernetes_namespace.ocl.metadata.0.name
  }
  spec {
    rule {
      host = "fhir.${local.environment}.${local.domain}"
      http {
        path {
          path = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.oclfhir.metadata.0.name
              port {
                number = kubernetes_service.oclfhir.spec.0.port.0.port
              }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.ingress]
}

resource "kubernetes_deployment" "oclflower" {
  metadata {
    name = "oclflower"
    labels = {
      App = "oclflower"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "oclflower"
      }
    }
    template {
      metadata {
        labels = {
          App = "oclflower"
        }
      }
      spec {
        subdomain = "flower"
        container {
          image = "docker.io/openconceptlab/oclapi2:qa"
          name  = "oclflower"
          image_pull_policy = "Always"

          command = ["bash","-c","./start_flower.sh"]

          port {
            container_port = 5555
          }

          env {
            name = "PYTHONUNBUFFERED"
            value = "0"
          }

          dynamic "env" {
            for_each = merge(local.api_config, {
              FLOWER_PORT = "5555"
            })
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = "0.1"
              memory = "512Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/healthcheck"
              port = 5555
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "oclflower" {
  metadata {
    name = "oclflower"
  }
  spec {
    selector = {
      App = kubernetes_deployment.oclflower.spec.0.template.0.metadata[0].labels.App
    }
    port {
      port        = 80
      target_port = 5555
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "oclflower" {
  metadata {
    name = "oclflower"
    namespace = kubernetes_namespace.ocl.metadata.0.name
  }
  spec {
    rule {
      host = "flower.${local.environment}.${local.domain}"
      http {
        path {
          path = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.oclflower.metadata.0.name
              port {
                number = kubernetes_service.oclflower.spec.0.port.0.port
              }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.ingress]
}

resource "kubernetes_deployment" "oclcelery" {
  metadata {
    name = "oclcelery"
    labels = {
      App = "oclcelery"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "oclcelery"
      }
    }
    template {
      metadata {
        labels = {
          App = "oclcelery"
        }
      }
      spec {
        subdomain = "celery"
        container {
          image = "docker.io/openconceptlab/oclapi2:qa"
          name  = "oclcelery"
          image_pull_policy = "Always"

          command = ["bash", "-c", "CELERY_WORKER_NAME=default ./start_celery_worker.sh -P prefork -Q default -c 2"]

          env {
            name = "PYTHONUNBUFFERED"
            value = "0"
          }

          dynamic "env" {
            for_each = merge(local.api_config, {
              API_HOST = "oclapi2"
              API_PORT = 80
            })
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = "0.2"
              memory = "512Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "oclcelerybeat" {
  metadata {
    name = "oclcelerybeat"
    labels = {
      App = "oclcelerybeat"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "oclcelerybeat"
      }
    }
    template {
      metadata {
        labels = {
          App = "oclcelerybeat"
        }
      }
      spec {
        subdomain = "celerybeat"
        container {
          image = "docker.io/openconceptlab/oclapi2:qa"
          name  = "oclcelerybeat"
          image_pull_policy = "Always"

          command = ["bash", "-c", "./start_celery_beat.sh"]

          env {
            name = "PYTHONUNBUFFERED"
            value = "0"
          }

          dynamic "env" {
            for_each = merge(local.api_config, {
              API_HOST = "oclapi2"
              API_PORT = 80
            })
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = "0.2"
              memory = "128Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "oclceleryindexing" {
  metadata {
    name = "oclceleryindexing"
    labels = {
      App = "oclceleryindexing"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "oclceleryindexing"
      }
    }
    template {
      metadata {
        labels = {
          App = "oclceleryindexing"
        }
      }
      spec {
        subdomain = "celeryindexing"
        container {
          image = "docker.io/openconceptlab/oclapi2:qa"
          name  = "oclceleryindexing"
          image_pull_policy = "Always"

          command = ["bash", "-c", "CELERY_WORKER_NAME=indexing ./start_celery_worker.sh -P prefork -Q indexing -c 5"]

          env {
            name = "PYTHONUNBUFFERED"
            value = "0"
          }

          dynamic "env" {
            for_each = merge(local.api_config, {
              API_HOST = "oclapi2"
              API_PORT = 80
            })
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = "0.2"
              memory = "1024Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "oclceleryconcurrent" {
  metadata {
    name = "oclceleryconcurrent"
    labels = {
      App = "oclceleryconcurrent"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "oclceleryconcurrent"
      }
    }
    template {
      metadata {
        labels = {
          App = "oclceleryconcurrent"
        }
      }
      spec {
        subdomain = "celeryconcurrent"
        container {
          image = "docker.io/openconceptlab/oclapi2:qa"
          name  = "oclceleryconcurrent"
          image_pull_policy = "Always"

          command = ["bash", "-c", "CELERY_WORKER_NAME=concurrent ./start_celery_worker.sh -P prefork -Q concurrent -c 5"]

          env {
            name = "PYTHONUNBUFFERED"
            value = "0"
          }

          dynamic "env" {
            for_each = merge(local.api_config, {
              API_HOST = "oclapi2"
              API_PORT = 80
            })
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = "0.2"
              memory = "1024Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "oclcelerybulkimportroot" {
  metadata {
    name = "oclcelerybulkimportroot"
    labels = {
      App = "oclcelerybulkimportroot"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "oclcelerybulkimportroot"
      }
    }
    template {
      metadata {
        labels = {
          App = "oclcelerybulkimportroot"
        }
      }
      spec {
        subdomain = "celerybulkimportroot"
        container {
          image = "docker.io/openconceptlab/oclapi2:qa"
          name  = "oclcelerybulkimportroot"
          image_pull_policy = "Always"

          command = ["bash", "-c", "CELERY_WORKER_NAME=bulk_import_root ./start_celery_worker.sh -Q bulk_import_root -c 1"]

          env {
            name = "PYTHONUNBUFFERED"
            value = "0"
          }

          dynamic "env" {
            for_each = merge(local.api_config, {
              API_HOST = "oclapi2"
              API_PORT = 80
            })
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = "0.2"
              memory = "2048Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "oclcelerybulkimport0-1" {
  metadata {
    name = "oclcelerybulkimport0-1"
    labels = {
      App = "oclcelerybulkimport0-1"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "oclcelerybulkimport0-1"
      }
    }
    template {
      metadata {
        labels = {
          App = "oclcelerybulkimport0-1"
        }
      }
      spec {
        subdomain = "celerybulkimport0-1"
        container {
          image = "docker.io/openconceptlab/oclapi2:qa"
          name  = "oclcelerybulkimport0-1"
          image_pull_policy = "Always"

          command = ["bash", "-c", "CELERY_WORKER_NAME=bulk_import_0_1 ./start_celery_worker.sh -Q bulk_import_0,bulk_import_1 -c 1"]

          env {
            name = "PYTHONUNBUFFERED"
            value = "0"
          }

          dynamic "env" {
            for_each = merge(local.api_config, {
              API_HOST = "oclapi2"
              API_PORT = 80
            })
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = "0.2"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "oclcelerybulkimport2-3" {
  metadata {
    name = "oclcelerybulkimport2-3"
    labels = {
      App = "oclcelerybulkimport2-3"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "oclcelerybulkimport2-3"
      }
    }
    template {
      metadata {
        labels = {
          App = "oclcelerybulkimport2-3"
        }
      }
      spec {
        subdomain = "celerybulkimport2-3"
        container {
          image = "docker.io/openconceptlab/oclapi2:qa"
          name  = "oclcelerybulkimport2-3"
          image_pull_policy = "Always"

          command = ["bash", "-c", "CELERY_WORKER_NAME=bulk_import_2_3 ./start_celery_worker.sh -Q bulk_import_2,bulk_import_3 -c 1"]

          env {
            name = "PYTHONUNBUFFERED"
            value = "0"
          }

          dynamic "env" {
            for_each = merge(local.api_config, {
              API_HOST = "oclapi2"
              API_PORT = 80
            })
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = "0.2"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}


resource "kubernetes_deployment" "oclweb2" {
  metadata {
    name   = "oclweb2"
    namespace = kubernetes_namespace.ocl.metadata.0.name
    labels = {
      App = "oclweb2"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "oclweb2"
      }
    }
    template {
      metadata {
        labels = {
          App = "oclweb2"
        }
      }
      spec {
        subdomain = "web"
        container {
          image = "docker.io/openconceptlab/oclweb2:qa"
          name  = "oclweb2"
          image_pull_policy = "Always"

          port {
            container_port = 4000
          }

          env {
            name = "PYTHONUNBUFFERED"
            value = "0"
          }

          dynamic "env" {
            for_each = local.web_config
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = "0.2"
              memory = "128Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "oclweb2" {
  metadata {
    name = "oclweb2"
    namespace = kubernetes_namespace.ocl.metadata.0.name
  }
  spec {
    selector = {
      App = kubernetes_deployment.oclweb2.spec.0.template.0.metadata[0].labels.App
    }

    port {
      port        = 80
      target_port = 4000
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "oclweb2" {
  metadata {
    name = "oclweb2"
    namespace = kubernetes_namespace.ocl.metadata.0.name
  }
  spec {
    rule {
      host = "${local.environment}.${local.domain}"
      http {
        path {
          path = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.oclweb2.metadata.0.name
              port {
                number = kubernetes_service.oclweb2.spec.0.port.0.port
              }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.ingress]
}