terraform {
  required_version = ">= 1.4.5, < 1.5"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "3.86.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.25.1"
    }
  }
}
