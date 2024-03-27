terraform {
  backend "azurerm" {
    resource_group_name  = "ocl"
    storage_account_name = "ocltestterraform"
    container_name       = "ocl-test-terraform"
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

resource "azurerm_resource_group" "ocl-test" {
  name     = "ocl-test"
  location = "westeurope"
}

resource "azurerm_log_analytics_workspace" "ocl-test" {
  name                = "ocl-test"
  location            = azurerm_resource_group.ocl-test.location
  resource_group_name = azurerm_resource_group.ocl-test.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_private_dns_zone" "ocl-test" {
  name                = "privatelink.westeurope.azmk8s.io"
  resource_group_name = azurerm_resource_group.ocl-test.name
}

resource "azurerm_user_assigned_identity" "ocl-test-aks-identity" {
  name                = "ocl-test-aks-identity"
  resource_group_name = azurerm_resource_group.ocl-test.name
  location            = azurerm_resource_group.ocl-test.location
}

resource "azurerm_role_assignment" "ocl-test" {
  scope                = azurerm_private_dns_zone.ocl-test.id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.ocl-test-aks-identity.principal_id
}


resource "azurerm_kubernetes_cluster" "ocl-test" {
  name                = "ocl-test"
  location            = azurerm_resource_group.ocl-test.location
  resource_group_name = azurerm_resource_group.ocl-test.name
  private_cluster_enabled = true
  dns_prefix = "ocltest"
  private_dns_zone_id = azurerm_private_dns_zone.ocl-test.id

  depends_on = [
    azurerm_role_assignment.ocl-test
  ]

  default_node_pool {
    name       = "default"
    node_count = 3
    vm_size    = "Standard_D11_v2"
  }

  identity {
    type = "SystemAssigned"
  }

  ingress_application_gateway {
    gateway_name = "ocl-test-ag"
    subnet_cidr = "10.225.0.0/16"
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