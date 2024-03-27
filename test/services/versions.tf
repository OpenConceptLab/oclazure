terraform {
  required_version = ">= 1.4.5, < 1.5"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "3.97.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.25.1"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }
}
