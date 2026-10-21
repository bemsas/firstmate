#!/usr/bin/env bash
# Archive acknowledged legacy process-event JSON pairs older than seven days.
# Usage: FM_HOME=/absolute/home fm-procevent-archive.sh [--apply]
# Default is a read-only preview. --apply creates one UTC-dated tar.gz under
# state/procevent-archive, verifies its contents, then removes unchanged pairs.
# Both regular files must be old; unacknowledged JSON, symlinks, orphan markers,
# and current .result captures are never touched. No automatic startup sweep.
set -euo pipefail
exec python3 "$(dirname "$0")/fm-housekeeping.py" archive "$@"
