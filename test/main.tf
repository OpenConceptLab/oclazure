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
  host = azurerm_kubernetes_cluster.ocl-test.kube_config.0.host

  client_certificate     = base64decode(azurerm_kubernetes_cluster.ocl-test.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.ocl-test.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.ocl-test.kube_config.0.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host = azurerm_kubernetes_cluster.ocl-test.kube_config.0.host

    client_certificate     = base64decode(azurerm_kubernetes_cluster.ocl-test.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.ocl-test.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.ocl-test.kube_config.0.cluster_ca_certificate)
  }
}

locals {
  api_config = merge(var.api_config, {
    ENVIRONMENT = "production"
    API_BASE_URL = "https://api.who.openconceptlab.org"
    API_HOST = "localhost"
    API_PORT = "8000"
    API_INTERNAL_BASE_URL = "http://oclapi2:80"

    DB_HOST = azurerm_postgresql_flexible_server.ocl-test.fqdn
    DB_PORT = "5432"
    DB_USER = azurerm_postgresql_flexible_server.ocl-test.administrator_login
    DB_PASSWORD = azurerm_postgresql_flexible_server.ocl-test.administrator_password
    DB_NAME = azurerm_postgresql_flexible_server_database.ocl-test.name

    ES_HOSTS = "elasticsearch-es-http.elastic-system:9200"
    ES_SCHEME = "https"
    ES_VERIFY_CERTS = "false"
    ES_USER = "elastic"
    ES_PASSWORD = data.kubernetes_secret.es_password.data["elastic"]

    REDIS_HOST = azurerm_redis_cache.ocl-test-redis.hostname
    REDIS_PORT = azurerm_redis_cache.ocl-test-redis.port
    REDIS_PASSWORD = azurerm_redis_cache.ocl-test-redis.primary_access_key

    FLOWER_HOST = "flower"
    FLOWER_PORT = "5555"

    IMPORT_DEMO_DATA = "true"

    EMAIL_HOST = "smtp.gmail.com"
    EMAIL_PORT = "587"
    EMAIL_USE_TLS = "true"

    #OIDC_SERVER_URL = "https://sso.openconceptlab.org"
    #OIDC_REALM = "ocl"
    FHIR_SUBDOMAIN = "fhir"
  })

  web_config = merge(var.web_config, {
    LOGIN_REDIRECT_URL = "https://app.who.openconceptlab.org/"
    LOGOUT_REDIRECT_URL = "https://app.who.openconceptlab.org/"
  })
}

resource "azurerm_resource_group" "ocl-test" {
  name     = "ocl-test"
  location = "eastus"
}

resource "azurerm_public_ip" "ocl-test" {
  name                = "ocl-test-public-ip"
  domain_name_label   = "openconceptlab"
  resource_group_name = azurerm_resource_group.ocl-test.name
  location            = azurerm_resource_group.ocl-test.location
  allocation_method   = "Static"
  sku = "Standard"

  tags = {
    environment = "test"
  }
}

resource "azurerm_public_ip" "ocl-test-api" {
  name                = "ocl-test-api-public-ip"
  domain_name_label   = "api-openconceptlab"
  resource_group_name = azurerm_resource_group.ocl-test.name
  location            = azurerm_resource_group.ocl-test.location
  allocation_method   = "Static"
  sku = "Standard"

  tags = {
    environment = "test"
  }
}

resource "azurerm_public_ip" "ocl-test-flower" {
  name                = "ocl-test-flower-public-ip"
  domain_name_label   = "flower-openconceptlab"
  resource_group_name = azurerm_resource_group.ocl-test.name
  location            = azurerm_resource_group.ocl-test.location
  allocation_method   = "Static"
  sku = "Standard"

  tags = {
    environment = "test"
  }
}

resource "azurerm_log_analytics_workspace" "ocl-test" {
  name                = "ocl-test"
  location            = azurerm_resource_group.ocl-test.location
  resource_group_name = azurerm_resource_group.ocl-test.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_kubernetes_cluster" "ocl-test" {
  name                = "ocl-test"
  location            = azurerm_resource_group.ocl-test.location
  resource_group_name = azurerm_resource_group.ocl-test.name
  dns_prefix          = "ocltest"

  default_node_pool {
    name       = "default"
    node_count = 3
    vm_size    = "Standard_D11_v2"
  }

  identity {
    type = "SystemAssigned"
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.ocl-test.id
    msi_auth_for_monitoring_enabled = true
  }

  tags = {
    Environment = "test"
  }
}

resource "azurerm_role_assignment" "ocl-test-network-aks" {
  scope                = azurerm_resource_group.ocl-test.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.ocl-test.identity[0].principal_id
}

resource "random_password" "pass" {
  length = 20
}

resource "helm_release" "eck-operator" {
  name       = "eck-operator"
  repository = "https://helm.elastic.co"
  chart      = "eck-operator"
  namespace         = "elastic-system"
  create_namespace  = true
  force_update = true
  dependency_update = true #helm repo update command
}

resource "kubernetes_manifest" "elasticsearch" {
  manifest = yamldecode(file("eck/elasticsearch.yaml"))

  depends_on = [
    helm_release.eck-operator
  ]
}

data "kubernetes_secret" "es_password" {
  metadata {
    name = "elasticsearch-es-elastic-user"
    namespace = "elastic-system"
  }

  depends_on = [
    kubernetes_manifest.elasticsearch
  ]
}

resource "helm_release" "cert-manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  namespace         = "cert-manager"
  create_namespace  = true
  force_update = true
  dependency_update = true
  set {
    name  = "installCRDs"
    value = "true"
  }
}

resource "kubernetes_manifest" "cert-manager" {
  manifest = yamldecode(file("cert-manager/clusterissuer.yaml"))

  depends_on = [
    helm_release.cert-manager
  ]
}

resource "azurerm_postgresql_flexible_server" "ocl-test" {
  name                   = "ocl-test-db"
  resource_group_name    = azurerm_resource_group.ocl-test.name
  location               = azurerm_resource_group.ocl-test.location
  version                = "14"
  administrator_login    = "ocladmin"
  administrator_password = random_password.pass.result
  zone                   = "1"
  storage_mb             = 32768
  sku_name               = "GP_Standard_D2s_v3"
  backup_retention_days  = 7
}

#resource "azurerm_postgresql_flexible_server_firewall_rule" "ocl-test" {
#  name             = "allow"
#  server_id        = azurerm_postgresql_flexible_server.ocl-test.id
#  start_ip_address = "0.0.0.0"
#  end_ip_address   = "255.255.255.255"
#}

resource "azurerm_postgresql_flexible_server_database" "ocl-test" {
  name      = "ocl-test-db"
  server_id = azurerm_postgresql_flexible_server.ocl-test.id
  collation = "en_US.utf8"
  charset   = "utf8"

  # prevent the possibility of accidental data loss
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_redis_cache" "ocl-test-redis" {
  name                = "ocl-test-redis"
  location            = azurerm_resource_group.ocl-test.location
  resource_group_name = azurerm_resource_group.ocl-test.name
  capacity            = 2
  family              = "C"
  sku_name            = "Basic"
  enable_non_ssl_port = true
  minimum_tls_version = "1.2"
  redis_version = "6"

  redis_configuration {

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
              cpu    = "0.5"
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
    annotations = {
      "service.beta.kubernetes.io/azure-dns-label-name" = azurerm_public_ip.ocl-test-api.domain_name_label
      "service.beta.kubernetes.io/azure-load-balancer-resource-group" = azurerm_resource_group.ocl-test.name
      "service.beta.kubernetes.io/azure-pip-name" = azurerm_public_ip.ocl-test-api.name
    }
  }
  spec {
    selector = {
      App = kubernetes_deployment.oclapi2.spec.0.template.0.metadata[0].labels.App
    }
    port {
      port        = 80
      target_port = 8000
    }

    type = "LoadBalancer"
  }
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
              cpu    = "0.5"
              memory = "512Mi"
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
      "service.beta.kubernetes.io/azure-dns-label-name" = azurerm_public_ip.ocl-test-api.domain_name_label
      "service.beta.kubernetes.io/azure-load-balancer-resource-group" = azurerm_resource_group.ocl-test.name
      "service.beta.kubernetes.io/azure-pip-name" = azurerm_public_ip.ocl-test-api.name
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

    type = "LoadBalancer"
  }
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
            for_each = local.api_config
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
        }
      }
    }
  }
}

resource "kubernetes_service" "oclflower" {
  metadata {
    name = "oclflower"
    annotations = {
      "service.beta.kubernetes.io/azure-dns-label-name" = azurerm_public_ip.ocl-test-flower.domain_name_label
      "service.beta.kubernetes.io/azure-load-balancer-resource-group" = azurerm_resource_group.ocl-test.name
      "service.beta.kubernetes.io/azure-pip-name" = azurerm_public_ip.ocl-test-flower.name
    }
  }
  spec {
    selector = {
      App = kubernetes_deployment.oclflower.spec.0.template.0.metadata[0].labels.App
    }
    port {
      port        = 80
      target_port = 5555
    }

    type = "LoadBalancer"
  }
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
            for_each = local.api_config
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
            for_each = local.api_config
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
            for_each = local.api_config
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
            for_each = local.api_config
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
            for_each = local.api_config
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
            for_each = local.api_config
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
          image = "docker.io/openconceptlab/oclweb2:production"
          name  = "oclweb2"
          image_pull_policy = "Always"

          port {
            container_port = 4000
          }

          env {
            name = "PYTHONUNBUFFERED"
            value = "0"
          }

          env {
            name = "API_URL"
            value = "http://${azurerm_public_ip.ocl-test-api.domain_name_label}.eastus.cloudapp.azure.com"
          }

          dynamic "env" {
            for_each = var.web_config
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
    annotations = {
      "service.beta.kubernetes.io/azure-dns-label-name" = azurerm_public_ip.ocl-test.domain_name_label
      "service.beta.kubernetes.io/azure-load-balancer-resource-group" = azurerm_resource_group.ocl-test.name
      "service.beta.kubernetes.io/azure-pip-name" = azurerm_public_ip.ocl-test.name
    }
  }
  spec {
    selector = {
      App = kubernetes_deployment.oclweb2.spec.0.template.0.metadata[0].labels.App
    }

    port {
      port        = 80
      target_port = 4000
    }

    type = "LoadBalancer"
  }
}

resource "azurerm_storage_account" "ocl-test-account" {
  name                     = "ocltestaccount"
  resource_group_name      = azurerm_resource_group.ocl-test.name
  location                 = azurerm_resource_group.ocl-test.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "ocl-test-exports" {
  name                  = "ocl-test-exports"
  storage_account_name  = azurerm_storage_account.ocl-test-account.name
  container_access_type = "blob"
}

resource "azurerm_user_assigned_identity" "ocl-test-exports-user" {
  location            = azurerm_resource_group.ocl-test.location
  name                = "ocl-test-exports"
  resource_group_name = azurerm_resource_group.ocl-test.name
}

resource "azurerm_role_assignment" "ocl-test-exports-role" {
  scope                = azurerm_storage_account.ocl-test-account.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.ocl-test-exports-user.principal_id
}

resource "kubernetes_ingress" "ocl-gateway" {
  metadata {
    name = "ocl-gateway"

    annotations = {
      "kubernetes.io/ingress.class" = "azure/application-gateway"
      "cert-manager.io/cluster-issuer" = "letsencrypt-staging"
      "cert-manager.io/acme-challenge-type" = "http01"
    }
  }

  spec {
    rule {
      host = "api.who.openconceptlab.org"
      http {
        path {
          backend {
            service_name = kubernetes_service.oclapi2.metadata.name
            service_port = kubernetes_service.oclapi2.spec.port.port
          }
        }
      }
    }

    rule {
      host = "app.who.openconceptlab.org"
      http {
        path {
          backend {
            service_name = kubernetes_service.oclweb2.metadata.name
            service_port = kubernetes_service.oclweb2.spec.port.port
          }
        }
      }
    }

    rule {
      host = "flower.who.openconceptlab.org"
      http {
        path {
          backend {
            service_name = kubernetes_service.oclflower.metadata.name
            service_port = kubernetes_service.oclflower.spec.port.port
          }
        }
      }
    }

    rule {
      host = "fhir.who.openconceptlab.org"
      http {
        path {
          backend {
            service_name = kubernetes_service.oclfhir.metadata.name
            service_port = kubernetes_service.oclfhir.spec.port.port
          }
        }
      }
    }

    tls {
      hosts = ["api.who.openconceptlab.org", "app.who.openconceptlab.org", "fhir.who.openconceptlab.org",
        "flower.who.openconceptlab.org"]
      secret_name = "letsencrypt-secret"
    }
  }
}