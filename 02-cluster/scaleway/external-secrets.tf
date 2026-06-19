# External Secrets Operator (ESO) "secret-zero".
#
# ESO can't fetch its own Infisical auth from Infisical via itself, so Terraform
# — which already has Infisical access — seeds that one credential here. This is
# the *only* ESO-related thing Terraform owns: the Infisical universal-auth
# clientId/clientSecret, in a Kubernetes Secret the ESO ClusterSecretStore reads.
#
# ESO itself (the controller + CRDs) is deployed by ArgoCD from the gitops repo
# (platform/scaleway), not from here — Terraform stays a one-time bootstrapper.
# Once ESO is up and authenticated via this secret, every other cluster secret
# flows from Infisical through ExternalSecret resources.
#
# Creds come from data.infisical_secrets.infisical (folder /kubernetes), written
# there by 01-iam/bootstrap/infisical (the "kubernetes" machine identity).

resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }

  depends_on = [scaleway_k8s_pool.default]
}

resource "kubernetes_secret" "infisical_universal_auth" {
  metadata {
    name      = "infisical-universal-auth"
    namespace = kubernetes_namespace.external_secrets.metadata[0].name
  }

  type = "Opaque"

  data = {
    clientId     = data.infisical_secrets.infisical.secrets["INFISICAL_UNIVERSAL_AUTH_CLIENT_ID"].value
    clientSecret = data.infisical_secrets.infisical.secrets["INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET"].value
  }
}
