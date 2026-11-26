#!/usr/bin/env bash
# Trades this job's GitHub OIDC token for a headscale preauth key (headscale-sts,
# gitops repo services/platform/headscale). Writes `key=<key>` to $GITHUB_OUTPUT,
# or nothing when headscale is unreachable. Tests: tests/test_debug_tailscale.py.
#
# Reads LOGIN_SERVER, and the GitHub Actions variables ACTIONS_ID_TOKEN_REQUEST_*
# and GITHUB_OUTPUT.
set -euo pipefail
if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "::error::no OIDC token available: the job needs 'permissions: id-token: write'"
  exit 1
fi
if ! curl -fsS --max-time 10 --retry 2 "$LOGIN_SERVER/sts/healthz" >/dev/null; then
  echo "::warning::headscale is unreachable at $LOGIN_SERVER (cluster down?): no live debugging for this run"
  exit 0
fi
token=$(curl -fsS --max-time 30 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$LOGIN_SERVER/sts" | jq -er .value)
echo "::add-mask::$token"
# Not retried: a token mints one key, a second attempt is refused.
key=$(curl --fail-with-body -sS --max-time 30 -X POST \
  -H "Authorization: Bearer $token" "$LOGIN_SERVER/sts/authkey") || {
  echo "::error::headscale-sts refused to mint a key: $key"
  exit 1
}
echo "::add-mask::$key"
echo "key=$key" >>"$GITHUB_OUTPUT"
