provider "azurerm" {
  features {}

  subscription_id = "e9a8f37f-c8bf-4dd5-b66e-f80e84714bde"
  client_id = ""
  app_id = ""
}

resource "azurerm_resource_group" "ocl" {
  name = "ocl"
  location = "eastus"
}

resource "azurerm_storage_account" "ocl_storage_tfstate" {
  name                     = "ocl_storage_tfstate"
  resource_group_name      = azurerm_resource_group.ocl.name
  location                 = azurerm_resource_group.ocl.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "ocl_tfstate_blob" {
  name                  = "ocl_storage_tfstate_blob"
  storage_account_name  = azurerm_storage_account.ocl_storage_tfstate.name
  container_access_type = "private"
}