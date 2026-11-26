#!/usr/bin/env bash
# Receive one Boston batch over fm-on.sh --stdin.
# Usage: fm-boston-batch-receive.sh <request|result> <correlation> <sha256>
# The relay validates all bytes and publishes an immutable receipt before the
# native check wake points at it. The queue lock spans wake and marker writes.
# Retrying a partial publication reuses the receipt and any still-queued wake.
set -euo pipefail

[ "$#" -eq 3 ] || { printf 'usage: fm-boston-batch-receive.sh <request|result> <correlation> <sha256>\n' >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIPT=$(python3 "$SCRIPT_DIR/fm-boston-batch-relay.py" receive "$@")
KEY="boston-batch:$1:$2"
MARKER="$FM_HOME/$RECEIPT.woken"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
trap 'fm_lock_release "$FM_WAKE_QUEUE_LOCK"' EXIT
if [ ! -d "$MARKER" ] || [ -L "$MARKER" ]; then
  queued=0
  fm_wake_queue_has_key_locked check "$KEY" || queued=$?
  case "$queued" in
    0) ;;
    1) fm_wake_append_locked check "$KEY" "check: Boston batch $1 $2 at $RECEIPT" ;;
    *) exit 1 ;;
  esac
  mkdir "$MARKER"
fi
printf 'received: %s\n' "$RECEIPT"
