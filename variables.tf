variable "platform_subscription_id" {
  description = "Azure subscription ID where rg-terraform-identities lives."
  type        = string
  default     = "bd99adad-06b5-4d1c-ace0-aa64bdf0a2fe"
}

variable "workload_subscription_id" {
  description = "Azure subscription ID for the workload resource groups."
  type        = string
}

variable "uami_location" {
  description = "Azure region for all UAMIs."
  type        = string
  default     = "canadacentral"
}
