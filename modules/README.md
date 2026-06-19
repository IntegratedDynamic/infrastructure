# modules/

Reusable Terraform modules shared across the roots in this repo.

Empty for now — the roots currently consume community modules
(`terraform-aws-modules/*`) directly. When a pattern is duplicated across roots
(e.g. an IAM identity used by more than one root), factor it out into a module
here and reference it with a relative `source = "../../modules/<name>"`.

Roots (the deployable configs) live under the numeric domain folders
`00-remote_state/`, `01-iam/`, and `02-cluster/`; this folder holds only
non-deployable, reusable building blocks.
