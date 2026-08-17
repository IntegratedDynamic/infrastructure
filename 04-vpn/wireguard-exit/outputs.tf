output "server_public_key" {
  description = "WireGuard exit-node server public key — non-secret, copy into gitops services/platform/wireguard-exit's values."
  value       = wireguard_asymmetric_key.server.public_key
}

output "server_private_key" {
  description = "WireGuard exit-node server private key — sensitive. Read directly by 05-secrets/openbao/managed via terraform_remote_state (kv/apps/wireguard-exit/server-key). Never committed here."
  value       = wireguard_asymmetric_key.server.private_key
  sensitive   = true
}

output "peer_public_keys" {
  description = "peer name -> public key. Non-secret. Read (with peer_addresses) by 05-secrets/openbao/managed via terraform_remote_state into kv/apps/wireguard-exit/peers, which the gitops repo's services/platform/wireguard-exit/secret syncs down — nothing hardcodes these."
  value       = { for name, key in wireguard_asymmetric_key.peer : name => key.public_key }
}

output "peer_addresses" {
  description = "peer name -> overlay tunnel address (var.peers[name].address, echoed back as its own output for the same reason as peer_public_keys above)."
  value       = { for name, cfg in var.peers : name => cfg.address }
}

output "peer_private_keys" {
  description = "peer name -> private key. Sensitive. Every entry stays local — see peer_confs — never committed, never round-tripped through OpenBao."
  value       = { for name, key in wireguard_asymmetric_key.peer : name => key.private_key }
  sensitive   = true
}

# peer name -> full rendered wg-quick config. Deliberately NOT written to
# disk by this root (no local_sensitive_file/for_each here) — same reasoning
# as 04-vpn/wireguard-site-to-site/outputs.tf: anyone running `terraform
# apply` on this root would otherwise end up with every peer's private key
# in plaintext on their own machine, not just their own. Extracting and
# writing just one peer's file is `mise run vpn-exit-generate`'s job
# (mise.toml), scoped to a single name via `terraform output -json
# peer_confs | jq -r '.["<name>"]'`.
output "peer_confs" {
  description = "peer name -> full rendered wg-quick config (sensitive). Never written to disk in bulk — see mise.toml's vpn-exit-generate task for how one peer's own file gets extracted."
  value       = { for name, doc in data.wireguard_config_document.peer : name => doc.conf }
  sensitive   = true
}
