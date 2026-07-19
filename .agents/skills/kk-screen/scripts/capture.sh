#!/bin/sh
set -eu

SKILL_SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
COMPLETECONTROL_ROOT=$(CDPATH= cd -- "$SKILL_SCRIPT_DIRECTORY/../../../.." && pwd -P)
CAPTURE_SCRIPT="$COMPLETECONTROL_ROOT/Scripts/kk-screenshot.py"

if [ ! -f "$CAPTURE_SCRIPT" ]; then
    echo "error: CompleteControl screenshot helper not found: $CAPTURE_SCRIPT" >&2
    exit 2
fi

exec python3 "$CAPTURE_SCRIPT" "$@"
