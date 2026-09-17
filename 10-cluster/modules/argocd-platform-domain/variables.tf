variable "name" {
  description = "ArgoCD Application name (also the helm_release name, prefixed \"argocd-\")."
  type        = string
}

variable "source_repo" {
  description = "Git repo URL the Application's chart is pulled from."
  type        = string
}

variable "target_revision" {
  description = "targetRevision of var.source_repo -- e.g. this repo's own infra_revision/effective_infra_revision, or a gitops-repo revision for a bootstrap-shaped Application."
  type        = string
}

variable "source_path" {
  description = "Path within var.source_repo the chart lives at."
  type        = string
}

variable "value_files" {
  description = "Helm valueFiles for the rendered Application, relative to var.source_path. Empty list omits the whole helm.valueFiles key (e.g. for a bootstrap-shaped Application driven entirely by parameters)."
  type        = list(string)
  default     = []
}

variable "parameters" {
  description = "Extra Helm parameters (name/value pairs) for the rendered Application, e.g. the \"revision\" gitops-repo pin every platform-apps domain expects, or a domain-specific override like activeClusterIssuer/hostSuffix."
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "timeout" {
  description = "helm_release timeout, for BOTH install and uninstall. Default matches every existing platform-apps domain (destroy must outlast ArgoCD's own cascade-delete via resources-finalizer.argocd.argoproj.io -- confirmed live 2026-08-25 that exceeds 5 minutes)."
  type        = number
  default     = 1800
}

variable "namespace" {
  description = "Namespace the rendered Application object itself lives in, and the destination namespace its own child resources sync into by default. Every existing platform-apps domain uses \"argocd\" for both."
  type        = string
  default     = "argocd"
}
