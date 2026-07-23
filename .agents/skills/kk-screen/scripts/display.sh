#!/bin/sh
set -eu

SKILL_SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
COMPLETECONTROL_ROOT=$(CDPATH= cd -- "$SKILL_SCRIPT_DIRECTORY/../../../.." && pwd -P)
DISPLAY_SCRIPT="$COMPLETECONTROL_ROOT/Scripts/kk-display.py"

if [ ! -f "$DISPLAY_SCRIPT" ]; then
    echo "error: CompleteControl display helper not found: $DISPLAY_SCRIPT" >&2
    exit 2
fi

exec python3 "$DISPLAY_SCRIPT" "$@"
