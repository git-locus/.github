#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# First-idea message scheduler, run by supervisord (program `first-idea-dm`)
# next to the API. Every FIRST_IDEA_DM_INTERVAL seconds it runs
# `manage.py send_first_idea_dms`, which sends the Locus Team message to each
# author whose first idea is at least ten minutes old (once per person, so an
# extra run is harmless).
#
# Off unless FIRST_IDEA_DM_ENABLED=1: the process then just sleeps, so
# supervisord has nothing to restart.
set -eu

INTERVAL="${FIRST_IDEA_DM_INTERVAL:-300}"
COMMAND="${FIRST_IDEA_DM_COMMAND:-python manage.py send_first_idea_dms}"

log() {
    echo "[first-idea-dm-loop] $*"
}

# A whole number of seconds, at least 1.
valid_interval() {
    case "$1" in
        "" | *[!0-9]*) return 1 ;;
    esac
    [ "$1" -gt 0 ]
}

# A failing run is logged, never fatal: the next run must still happen.
run_command() {
    log "running: $COMMAND"
    # shellcheck disable=SC2086  # the command is meant to be word-split
    if $COMMAND; then
        log "done"
    else
        log "FAILED with status $?"
    fi
}

main() {
    if [ "${FIRST_IDEA_DM_ENABLED:-0}" != "1" ]; then
        log "FIRST_IDEA_DM_ENABLED is not 1: the first-idea message is off"
        while true; do sleep 86400; done
    fi
    if ! valid_interval "$INTERVAL"; then
        log "FIRST_IDEA_DM_INTERVAL must be a number of seconds, got '$INTERVAL'"
        exit 1
    fi
    log "first-idea message on, every $INTERVAL seconds"
    while true; do
        sleep "$INTERVAL"
        run_command
    done
}

# Tests source this file to reach the functions above.
if [ -z "${FIRST_IDEA_DM_LOOP_SOURCED:-}" ]; then
    main
fi
