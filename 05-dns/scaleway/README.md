# 05-dns/scaleway — what a cluster needs to manage DNS

One Scaleway identity, `external-dns`, limited to DNS zone records
(`DomainsDNSFullAccess` on the project that holds scalepack.fr's zone). Inside
the cluster, external-dns and cert-manager's DNS01 webhook use it. No zone or
record is Terraform-managed here.

| Output | Read by |
|---|---|
| `access_key`, `secret_key` | `10-cluster/scaleway` (in-cluster Secrets), `11-secrets/openbao/managed` (copy in OpenBao) |

```bash
cd live/core/main/05-dns/scaleway
terragrunt plan
```
