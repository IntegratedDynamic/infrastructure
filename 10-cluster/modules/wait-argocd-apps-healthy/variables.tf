variable "job_name" {
  description = "Name for the Kubernetes Job (must be a valid Kubernetes resource name)."
  type        = string
}

variable "app_names" {
  description = "ArgoCD Application names (in the argocd namespace) this Job polls until every one reports sync=Synced AND health=Healthy."
  type        = list(string)
}

variable "service_account_name" {
  description = "ServiceAccount (in the argocd namespace) with get/list on the Applications resource — see argocd.tf's kubernetes_service_account.wait_platform_apps, shared by every instance of this module."
  type        = string
}

variable "revision_trigger" {
  description = <<-EOT
    Opaque value written into the Job's pod env (e.g. a helm_release's own
    .metadata.revision). Forces a fresh Job whenever the thing this gate
    watches is redeployed, AND supplies Terraform's implicit dependency on
    whatever produced this value -- same trick argocd.tf's own
    PLATFORM_APPS_REVISION/BOOTSTRAP_REVISION env vars already use.
  EOT
  type        = string
}

variable "active_deadline_seconds" {
  description = "Overall polling budget for the Job itself, in seconds."
  type        = number
  default     = 1800
}

variable "create_timeout" {
  description = "Terraform's own wait on the Job's Complete condition. Must stay above active_deadline_seconds, same reasoning as the pre-module wait jobs' own timeouts block."
  type        = string
  default     = "35m"
}
