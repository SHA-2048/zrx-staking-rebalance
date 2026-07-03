#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

BROADCAST=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --broadcast)
      BROADCAST=true
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

SCRIPT="$1"
CONTRACT_NAME="$(basename "$SCRIPT" .s.sol)"
shift

SIGNER_FLAGS=()
# Keep PRIVATE_KEY out of process arguments. Solidity scripts read it from the
# subprocess environment and call vm.startBroadcast(privateKey) internally.
if [ -n "${LEDGER:-}" ]; then
  SIGNER_FLAGS+=(--ledger)
fi
if [ -n "${TREZOR:-}" ]; then
  SIGNER_FLAGS+=(--trezor)
fi
if [ -n "${MNEMONIC_INDEX:-}" ]; then
  SIGNER_FLAGS+=(--mnemonic-index "$MNEMONIC_INDEX")
fi
if [ -n "${HD_PATHS:-}" ]; then
  SIGNER_FLAGS+=(--hd-paths "$HD_PATHS")
fi

BROADCAST_FLAG=""
if [ "$BROADCAST" = true ]; then
  BROADCAST_FLAG="--broadcast"
fi

# shellcheck disable=SC2086
forge script "${SCRIPT}:${CONTRACT_NAME}" \
  --rpc-url "$RPC_URL" \
  $BROADCAST_FLAG \
  --slow \
  "${SIGNER_FLAGS[@]}" \
  "$@"
