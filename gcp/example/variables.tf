# The module's required inputs. Descriptions and validations live in
# ../variables.tf.

variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "github_org" {
  type = string
}

variable "github_app_id" {
  type = string
}

variable "github_app_installation_id" {
  type = string
}

variable "github_app_private_key_secret" {
  type = string
}

variable "github_webhook_secret_id" {
  type = string
}

variable "runner_group" {
  type = string
}

variable "repositories" {
  type = list(string)
}
