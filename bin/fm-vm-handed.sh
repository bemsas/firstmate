#!/usr/bin/env bash
# SHA-bound VM validation handoffs, with an explicit home to avoid cross-home writes.
# Usage: FM_HOME=/absolute/home fm-vm-handed.sh <check|record> <pr_number> <head_sha>
#        FM_HOME=/absolute/home fm-vm-handed.sh pending <owner/repository> <pr_number>
#        FM_HOME=/absolute/home fm-vm-handed.sh pending-open <owner/repository>
# pending-open batches missing open heads into one paginated API lookup.
# state/vm-handed.txt stores '<pr_number> <full_head_sha>' lines, one per handoff.
# check returns 0 only for that exact pair, 1 if absent; legacy bare numbers never
# suppress a new head. record preserves legacy history in vm-handed.legacy.txt
# on first write and atomically normalizes the ledger, deduplicating exact pairs.
# Record only after a successful VM send, using the head actually sent.
# pending obtains the current head via gh-axi; prints the missing pair, or nothing
# when already handed or closed. Lookup failures return nonzero.
set -euo pipefail
exec python3 "$(dirname "$0")/fm-housekeeping.py" handed "$@"
