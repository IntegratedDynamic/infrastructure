# Required to exist for `mise run local-apply` (reads env/${workspace}.tfvars
# unconditionally) but empty on purpose: default.auto.tfvars is passed *after*
# this file in that task, so it wins for any variable set in both — including
# gitops_revision. Override gitops_revision there, not here.
