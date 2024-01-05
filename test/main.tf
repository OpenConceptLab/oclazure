terraform {
  backend "azurerm" {
    resource_group_name  = "ocl"
    storage_account_name = "ocltesttfstate"
    container_name       = "ocl-test-tfstate"
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

provider "kubernetes" {
  host = azurerm_kubernetes_cluster.ocl_test.kube_config.0.host

  client_certificate     = base64decode(azurerm_kubernetes_cluster.ocl_test.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.ocl_test.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.ocl_test.kube_config.0.cluster_ca_certificate)
}

resource "azurerm_resource_group" "ocl_test" {
  name     = "ocl-test"
  location = "eastus"
}

resource "azurerm_public_ip" "ocl_test" {
  name                = "ocl-test-public-ip"
  resource_group_name = azurerm_resource_group.ocl_test.name
  location            = azurerm_resource_group.ocl_test.location
  allocation_method   = "Static"
  sku = "Standard"

  tags = {
    environment = "test"
  }
}

resource "azurerm_kubernetes_cluster" "ocl_test" {
  name                = "ocl-test"
  location            = azurerm_resource_group.ocl_test.location
  resource_group_name = azurerm_resource_group.ocl_test.name
  dns_prefix          = "ocltest"

  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "Standard_D11_v2"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    Environment = "test"
  }
}

resource "azurerm_role_assignment" "ocl-test-network-aks" {
  scope                = azurerm_resource_group.ocl_test.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.ocl_test.identity[0].principal_id
}

resource "azurerm_postgresql_server" "ocl-test-db" {
  name                = "ocl-test-db"
  location            = azurerm_resource_group.ocl_test.location
  resource_group_name = azurerm_resource_group.ocl_test.name

  sku_name = "B_Gen5_2"

  storage_mb                   = 5120
  backup_retention_days        = 7
  geo_redundant_backup_enabled = false
  auto_grow_enabled            = true

  administrator_login          = var.db_admin_user
  administrator_login_password = var.db_admin_password
  version                      = "9.5"
  ssl_enforcement_enabled      = true
}

resource "azurerm_postgresql_database" "ocl-test-db" {
  name                = "ocltestdb"
  resource_group_name = azurerm_resource_group.ocl_test.name
  server_name         = azurerm_postgresql_server.ocl-test-db.name
  charset             = "UTF8"
  collation           = "English_United States.1252"

  # prevent the possibility of accidental data loss
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_redis_cache" "ocl-test-redis" {
  name                = "ocl-test-redis"
  location            = azurerm_resource_group.ocl_test.location
  resource_group_name = azurerm_resource_group.ocl_test.name
  capacity            = 2
  family              = "C"
  sku_name            = "Basic"
  enable_non_ssl_port = false
  minimum_tls_version = "1.2"

  redis_configuration {
  }
}

resource "azurerm_elastic_cloud_elasticsearch" "ocl-test-es" {
  name                        = "ocl-test-es"
  resource_group_name         = azurerm_resource_group.ocl_test.name
  location                    = azurerm_resource_group.ocl_test.location
  sku_name                    = "ess-consumption-2024_Monthly"
  elastic_cloud_email_address = "jon@openconceptlab.org"
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
        container {
          image = "docker.io/openconceptlab/oclapi2:production"
          name  = "oclapi2"

          port {
            container_port = 8000
          }

          dynamic "env" {
            for_each = merge(var.api_config, {
              DB_HOST = azurerm_postgresql_server.ocl-test-db.fqdn
              DB_USER = azurerm_postgresql_server.ocl-test-db.administrator_login
              DB_PASSWORD = azurerm_postgresql_server.ocl-test-db.administrator_login_password
              DB_NAME = azurerm_postgresql_database.ocl-test-db.name

              REDIS_HOST = azurerm_redis_cache.ocl-test-redis.hostname
              REDIS_PORT = azurerm_redis_cache.ocl-test-redis.port
              REDIS_PASSWORD = azurerm_redis_cache.ocl-test-redis.primary_access_key

              ES_HOSTS = "ocl-test-es.es.eastus.azure.elastic-cloud.com"
            })
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "0.1"
              memory = "512Mi"
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
        container {
          image = "docker.io/openconceptlab/oclweb2:production"
          name  = "oclweb2"

          port {
            container_port = 4000
          }

          dynamic "env" {
            for_each = var.web_config
            content {
              name = env.key
              value = env.value
            }
          }

          resources {
            limits = {
              cpu    = "0.2"
              memory = "128Mi"
            }
            requests = {
              cpu    = "0.1"
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
    annotations = {
      #"service.beta.kubernetes.io/azure-dns-label-name" = "app"
      "service.beta.kubernetes.io/azure-load-balancer-resource-group" = azurerm_resource_group.ocl_test.name
      "service.beta.kubernetes.io/azure-pip-name" = azurerm_public_ip.ocl_test.name
    }
  }
  spec {
    selector = {
      App = kubernetes_deployment.oclweb2.spec.0.template.0.metadata[0].labels.App
    }

    port {
      port        = 4000
      target_port = 80
    }

    type = "LoadBalancer"
  }
}

resource "kubernetes_service" "oclapi2" {
  metadata {
    name = "oclapi2"
    annotations = {
      #"service.beta.kubernetes.io/azure-dns-label-name" = "api2"
      "service.beta.kubernetes.io/azure-load-balancer-resource-group" = azurerm_resource_group.ocl_test.name
      "service.beta.kubernetes.io/azure-pip-name" = azurerm_public_ip.ocl_test.name
    }
  }
  spec {
    selector = {
      App = kubernetes_deployment.oclapi2.spec.0.template.0.metadata[0].labels.App
    }
    port {
      port        = 8000
      target_port = 80
    }

    type = "LoadBalancer"
  }
}