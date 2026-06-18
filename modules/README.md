# modules/

Reusable Terraform modules shared across the roots in this repo.

Empty for now — the roots currently consume community modules
(`terraform-aws-modules/*`) directly. When a pattern is duplicated across roots
(e.g. a Scaleway CI IAM identity used by both `ci/10-scaleway/` and a future
`ci/11-scaleway-tf/`), factor it out into a module here and reference it with a
relative `source = "../../modules/<name>"`.

Roots (the deployable configs) live under the domain folders `state/`,
`identity/`, `ci/`, and `cluster/`; this folder holds only non-deployable,
reusable building blocks.
