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

resource "azurerm_resource_group" "ocl_test" {
  name     = "ocl-test"
  location = "eastus"
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
    Environment = "Test"
  }
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

  administrator_login          = "psqladmin"
  administrator_login_password = "H@Sh1CoR3!"
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

/*resource "azurerm_redis_cache" "ocl-test-redis" {
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
}*/

/*resource "azurerm_elastic_cloud_elasticsearch" "test" {
  name                        = "ocl-test-es"
  resource_group_name         = azurerm_resource_group.ocl_test.name
  location                    = azurerm_resource_group.ocl_test.location
  sku_name                    = "ess-monthly-consumption"
  elastic_cloud_email_address = "jon@openconceptlab.org"
}*/