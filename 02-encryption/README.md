# 02-encryption — what this domain is for

Encryption exists to protect data from unauthorized access — and the most
critical data to protect is your secrets. **OpenBao** was picked to hold
those secrets (`11-secrets/openbao`) — open source, mature, and well
integrated with Kubernetes.

To stay concise: OpenBao needs an encryption key — think of it as a master
key — to auto-unseal itself. Some cloud providers, AWS and GCP among them,
offer deep, OpenBao-compatible integrations that shrink that key's exposure
surface and make running OpenBao easier. That's what this domain provisions:
the key and the minimal credential OpenBao needs to reach it, on whichever
provider offers that integration (AWS today — see below for why not
Scaleway).

Useful links:
- [Auto-unseal plugins](https://openbao.org/community/rfcs/auto-unseal-plugins/)
- [Security model](https://openbao.org/docs/internals/security/)
- [Seal/Unseal concepts](https://openbao.org/docs/concepts/seal/)

Unlike the other domain READMEs in this repo, this one isn't
provider-agnostic on purpose: the actual driving constraint here isn't a
generic architectural choice, it's OpenBao's own auto-unseal plugin support —
which cloud a key can live in is dictated by which plugins OpenBao ships, not
by preference. That constraint is strong and specific enough that pretending
this domain is vendor-neutral would just be less honest.

## The contract

- **The key/credential material only**, scoped to what OpenBao's auto-unseal
  plugin needs to authenticate — nothing broader, and no IAM here is meant
  for CI or for anything outside OpenBao's own runtime.
