variable "az_subscription_id" {
  description = "Azure subscription id"
  type        = string
}

variable "az_client_id" {
  description = "Azure client id"
  type        = string
}

variable "az_client_secret" {
  description = "Azure client secret"
  type = string
}

variable "az_tenant_id" {
  description = "Azure tenant id"
  type = string
}

variable "db_admin_user" {
  description = "DB admin user"
  type = string
}

variable "db_admin_password" {
  description = "DB admin password"
  type = string
}

variable "web_config" {
  description = "OCL web config"
  type = map(string)
}

variable "api_config" {
  description = "OCL api config"
  type = map(string)
}