# This repo follow GitOps convention & standard. 
# Which means even `local` environment do get it's own official environment file.
# Treat this file as an example file for any local environment. But only push what should be pushed.
# For secrets, please at least use a .gitingored file extension (such as *.auto.tfvars files, which are apply by default, with lower precedence)


# infisical_client_id     = ""
# infisical_client_secret = ""

 # By default, terraform should default this variable into the most production-ish reference you have, as default value within `variables.tf`, and keep that variable commented in git.
 # This is an expected behavior, as CI tests regarding local environment will exploit this behavior to keep things DRY.
 # This is only true for any "local" env files
# gitops_revision = "main"
