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