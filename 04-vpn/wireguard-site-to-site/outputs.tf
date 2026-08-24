output "server_public_key" {
  description = "WireGuard server public key — non-secret, copy into gitops services/platform/wireguard's values."
  value       = wireguard_asymmetric_key.server.public_key
}

output "server_private_key" {
  description = "WireGuard server private key — sensitive. Read directly by 11-secrets/openbao/managed via terraform_remote_state (kv/apps/wireguard/server-key). Never committed here."
  value       = wireguard_asymmetric_key.server.private_key
  sensitive   = true
}

output "peer_public_keys" {
  description = "peer name -> public key. Non-secret. Read (with peer_addresses) by 11-secrets/openbao/managed via terraform_remote_state into kv/apps/wireguard/peers, which the gitops repo's services/platform/wireguard/init syncs down — nothing hardcodes these."
  value       = { for name, key in wireguard_asymmetric_key.peer : name => key.public_key }
}

output "peer_addresses" {
  description = "peer name -> overlay tunnel address (var.peers[name].address, echoed back as its own output for the same reason as peer_public_keys above)."
  value       = { for name, cfg in var.peers : name => cfg.address }
}

output "peer_private_keys" {
  description = "peer name -> private key. Sensitive. ci-github-actions is read directly by 11-secrets/openbao/managed via terraform_remote_state; every other entry stays local — see peer_confs — never committed, never round-tripped through OpenBao."
  value       = { for name, key in wireguard_asymmetric_key.peer : name => key.private_key }
  sensitive   = true
}

# peer name -> full rendered wg-quick config. Deliberately NOT written to
# disk by this root (no local_sensitive_file/for_each here) — that would
# mean anyone running `terraform apply` on this root ends up with every
# peer's private key in plaintext on their own machine, not just their
# own. Extracting and writing just one peer's file is `mise run
# vpn-generate`'s job (mise.toml), scoped to a single name via
# `terraform output -json peer_confs | jq -r '.["<name>"]'`.
output "peer_confs" {
  description = "peer name -> full rendered wg-quick config (sensitive). Never written to disk in bulk — see mise.toml's vpn-generate task for how one peer's own file gets extracted."
  value       = { for name, doc in data.wireguard_config_document.peer : name => doc.conf }
  sensitive   = true
}
