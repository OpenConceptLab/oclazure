provider "azurerm" {
  features {}

  subscription_id = var.az_subscription_id
  client_id = var.az_client_id
  client_secret = var.az_client_secret
  tenant_id = var.az_tenant_id
}

resource "azurerm_resource_group" "ocl" {
  name = "ocl"
  location = "westeurope"
}

resource "azurerm_storage_account" "ocl_test_terraform" {
  name                     = "ocltestterraform"
  resource_group_name      = azurerm_resource_group.ocl.name
  location                 = azurerm_resource_group.ocl.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

}

resource "azurerm_storage_container" "ocl_test_tfstate" {
  name                  = "ocl-test-terraform"
  storage_account_name  = azurerm_storage_account.ocl_test_terraform.name
  container_access_type = "private"
}