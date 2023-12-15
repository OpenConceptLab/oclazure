terraform {
  required_version = ">= 1.4.5, < 1.5"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "3.85.0"
    }
  }
}
