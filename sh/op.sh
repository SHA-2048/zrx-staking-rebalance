#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

# Prompt for a human-readable amount and convert it to wei.
ask_amount() {
  local var="$1"
  local value
  while true; do
    read -r -p "Amount (human readable, e.g. 1000): " value
    if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      eval "$var=\"$value\""
      return
    fi
    echo "Invalid amount, please enter a number."
  done
}

# Prompt for the signer and export the relevant environment variables.
ask_signer() {
  echo ""
  echo "Select signer:"
  select method in "private-key" "ledger" "trezor" "mnemonic"; do
    case "$method" in
      private-key)
        read -s -r -p "Private key (0x...): " key
        echo ""
        if [[ ! "$key" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
          echo "Invalid private key"
          exit 1
        fi
        export PRIVATE_KEY="$key"
        break
        ;;
      ledger)
        export LEDGER=1
        break
        ;;
      trezor)
        export TREZOR=1
        break
        ;;
      mnemonic)
        local idx path
        read -r -p "Mnemonic index: " idx
        [[ "$idx" =~ ^[0-9]+$ ]] || { echo "Invalid index"; exit 1; }
        export MNEMONIC_INDEX="$idx"
        read -r -p "HD path (optional): " path
        [ -n "$path" ] && export HD_PATHS="$path"
        break
        ;;
      *)
        echo "Invalid choice"
        ;;
    esac
  done
}

# Track whether the user chose to execute (broadcast) or simulate.
EXECUTE_MODE=false

ask_mode() {
  local mode
  read -r -p "Run mode — (s)imulate or (e)xecute? " mode
  if [ "$mode" = "e" ] || [ "$mode" = "E" ]; then
    EXECUTE_MODE=true
  else
    EXECUTE_MODE=false
  fi
}

# Confirm before executing.
confirm() {
  if [ "$EXECUTE_MODE" = true ]; then
    local ok
    read -r -p "This will broadcast to the network. Continue? (y/N) " ok
    if [ "$ok" != "y" ] && [ "$ok" != "Y" ]; then
      echo "Aborted."
      exit 1
    fi
  fi
}

# Run a shell operation script, forwarding the chosen signer env vars.
run_op() {
  local script="$1"
  shift
  echo ""
  echo "▶ Running: $script $*"
  if [ -n "${PRIVATE_KEY:-}" ]; then
    echo "  signer: private-key"
  elif [ -n "${LEDGER:-}" ]; then
    echo "  signer: ledger"
  elif [ -n "${TREZOR:-}" ]; then
    echo "  signer: trezor"
  elif [ -n "${MNEMONIC_INDEX:-}" ]; then
    echo "  signer: mnemonic (index $MNEMONIC_INDEX)"
  fi
  local flags=()
  if [ "$EXECUTE_MODE" = true ]; then
    echo "  mode: execute (broadcast)"
    flags+=(--broadcast)
  else
    echo "  mode: simulate"
  fi
  "$(dirname "$0")/$script" "${flags[@]}" "$@"
}

echo "Select operation:"
select op in \
  "stake-delegate" \
  "delegate-equal" \
  "redelegate" \
  "wrap" \
  "wrap-multi-delegate" \
  "treasury" \
  "quit"; do

  case "$op" in
    stake-delegate)
      ask_amount amount
      ask_mode
      if [ "$EXECUTE_MODE" = true ]; then
        ask_signer
      fi
      confirm
      run_op stake-and-delegate.sh "$amount"
      break
      ;;

    delegate-equal)
      ask_amount amount
      ask_mode
      if [ "$EXECUTE_MODE" = true ]; then
        ask_signer
      fi
      confirm
      run_op delegate-equal.sh "$amount"
      break
      ;;

    redelegate)
      echo "Select redelegate mode:"
      select mode in "undelegate-all" "redelegate-all" "redelegate-amount"; do
        [ -n "$mode" ] && break
      done
      target_amount=0
      if [ "$mode" = "redelegate-amount" ]; then
        ask_amount target_amount
      fi
      ask_mode
      if [ "$EXECUTE_MODE" = true ]; then
        ask_signer
      fi
      confirm
      run_op redelegate.sh "$mode" "$target_amount"
      break
      ;;

    wrap)
      echo "Select wrap mode:"
      select mode in "liquid" "full" "exclude-pools" "unstake"; do
        [ -n "$mode" ] && break
      done
      ask_mode
      if [ "$EXECUTE_MODE" = true ]; then
        ask_signer
      fi
      confirm
      run_op wrap-governance.sh "$mode"
      break
      ;;

    wrap-multi-delegate)
      delegatees=""
      amounts=""
      read -r -p "Delegatees (comma-separated addresses): " delegatees
      read -r -p "Amounts (comma-separated, human readable): " amounts
      export DELEGATEES="$delegatees"
      export AMOUNTS="$amounts"
      ask_mode
      if [ "$EXECUTE_MODE" = true ]; then
        ask_signer
      fi
      confirm
      run_op wrap-governance-multi-delegate.sh
      break
      ;;

    treasury)
      echo "Select treasury mode:"
      select mode in "propose" "execute"; do
        [ -n "$mode" ] && break
      done
      ask_mode
      if [ "$EXECUTE_MODE" = true ]; then
        ask_signer
      fi
      confirm
      if [ "$mode" = "execute" ]; then
        proposal_id=""
        read -r -p "Proposal ID: " proposal_id
        run_op treasury.sh "$mode" "$proposal_id"
      else
        run_op treasury.sh "$mode"
      fi
      break
      ;;

    quit)
      echo "Goodbye."
      exit 0
      ;;

    *)
      echo "Invalid choice"
      ;;
  esac
done
