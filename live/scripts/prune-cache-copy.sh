#!/usr/bin/env bash
# Called by live/root.hcl's after_hook (init-from-module), right after Terragrunt
# copied the repo into its cache dir. A local `source` with `//` at the repo root
# copies the WHOLE repo, gitignored files included: WireGuard private keys
# (04-vpn/*/generated/*.conf) and every root's local *.auto.tfvars (OpenBao,
# Tailscale, ...) would be duplicated into every unit's .terragrunt-cache.
# Drop them from the COPY. Only this root's own *.auto.tfvars is kept: that is
# the documented local-override mechanism (10-cluster/scaleway/local.auto.tfvars).
#
# Usage: prune-cache-copy.sh <cache copy of the repo root> <this root's path in the repo>
set -euo pipefail

cache_root=${1:?cache copy root}
own_root=${2:?root path}

# This script deletes files: it must be impossible for it to touch the real tree.
case "$cache_root" in
  */.terragrunt-cache/*) ;;
  *) echo "prune-cache-copy: refusing to prune '$cache_root' (not inside a .terragrunt-cache)" >&2; exit 1 ;;
esac
[ -d "$cache_root" ] || exit 0

find "$cache_root" -type f -path '*/generated/*' -delete
find "$cache_root" -type f -name '*.conf' -delete
find "$cache_root" -type f -name '*.auto.tfvars' -not -path "$cache_root/$own_root/*" -delete
