variable "platform_subscription_id" {
  description = "Azure subscription ID where rg-terraform-identities lives."
  type        = string
  default     = "bd99adad-06b5-4d1c-ace0-aa64bdf0a2fe"
}

variable "workload_subscription_id" {
  description = "Azure subscription ID for the workload resource groups."
  type        = string
  default     = "e21b59f3-d80c-435e-a2e3-0b7a77770e38"
}

variable "uami_location" {
  description = "Azure region for all UAMIs."
  type        = string
  default     = "canadacentral"
}
