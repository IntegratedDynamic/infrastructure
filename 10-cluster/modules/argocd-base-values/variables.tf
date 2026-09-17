variable "argocd_controller_memory_limit_mib" {
  description = "controller.resources.limits.memory, in MiB. GOMEMLIMIT (see values.yaml.tftpl) is derived from this at 85% -- ArgoCD's own documented mitigation ratio for OOMKilled events, splitting the difference of its 80-90% recommended range."
  type        = number
  default     = 1500
}
