#!/usr/bin/env bash
# bash live-handoff.sh <merged|deployed|rolled-back|unknown> <candidate-revision> <transition-epoch|-> [<served-revision> <observed-epoch> <handoff-start-epoch>]
# Formats evidence from the project's delivery owner for one release and environment.
# Times are UTC Unix seconds. Use - when the latest transition is unknown.
# Omitting the receipt reports live verification as unknown.
set -eu

case "$#" in
  3|6) ;;
  *) printf 'usage: bash live-handoff.sh <state> <revision> <transition-epoch|-> [<served-revision> <observed-epoch> <handoff-start-epoch>]\n' >&2; exit 2 ;;
esac

state=$1 candidate=$2 transition=$3 served=${4:-} observed=${5:-} handoff_start=${6:-}
revision_pattern='^([0-9a-f]{40}|[0-9a-f]{64})$'
epoch_pattern='^[1-9][0-9]{0,10}$'

[[ "$candidate" =~ $revision_pattern ]] || { printf 'An exact candidate revision is required.\n' >&2; exit 2; }
case "$state" in
  merged) printf 'Merged %s.\n' "$candidate" ;;
  deployed) printf 'Deployed %s.\n' "$candidate" ;;
  rolled-back) printf 'Rolled back %s.\n' "$candidate" ;;
  unknown) printf 'Delivery state unknown for %s.\n' "$candidate" ;;
  *) printf 'Unknown delivery state %s.\n' "$state" >&2; exit 2 ;;
esac

if [ "$state" = unknown ] || ! [[ "$transition" =~ $epoch_pattern && "$served" =~ $revision_pattern &&
    "$observed" =~ $epoch_pattern && "$handoff_start" =~ $epoch_pattern ]]; then
  printf 'Live verification unknown.\n'
elif [ "$observed" -le "$transition" ]; then
  printf 'Live verification stale. The observation precedes or coincides with the latest transition.\n'
elif [ "$observed" -lt "$handoff_start" ]; then
  printf 'Live verification stale. The observation predates this handoff.\n'
elif [ "$state" = rolled-back ] && [ "$served" = "$candidate" ]; then
  printf 'Live verification conflicts with the rollback. Recheck the delivery state.\n'
elif [ "$served" != "$candidate" ]; then
  printf 'Verified served revision %s at %s.\n' "$served" "$observed"
else
  printf 'Live revision %s verified at %s.\n' "$served" "$observed"
fi
