variable "region" { type = string }
variable "account_id" { type = string }
variable "name_prefix" {
  type    = string
  default = "wad-law"
}

variable "db_username" {
  type      = string
  sensitive = true
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "llm_api_key" {
  type      = string
  sensitive = true
}

variable "poly_proxy_address" {
  type      = string
  sensitive = true
}

variable "poly_private_key" {
  type      = string
  sensitive = true
}

variable "key_name" {
  description = "The name of the SSH key pair to use for EC2 instances"
  type        = string
}

 