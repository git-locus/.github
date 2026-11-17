#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Scheduled ideas publisher, run by supervisord (program `scheduled-publish`)
# next to the API. Every SCHEDULED_PUBLISH_INTERVAL seconds it runs
# `manage.py publish_scheduled`, which publishes the queued ideas whose time
# has come. A run starts only when the previous one has ended, so two runs of
# this loop never overlap, and the command itself is safe to run twice at once.
#
# Off unless SCHEDULED_PUBLISH_ENABLED=1: the process then just sleeps, so
# supervisord has nothing to restart.
set -eu

INTERVAL="${SCHEDULED_PUBLISH_INTERVAL:-60}"
COMMAND="${SCHEDULED_PUBLISH_COMMAND:-python manage.py publish_scheduled}"
# A run that hangs would stop every later one, so it is cut after this many
# seconds.
RUN_TIMEOUT="${SCHEDULED_PUBLISH_TIMEOUT:-300}"

log() {
    echo "[scheduled-publish-loop] $*"
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
    if timeout "$RUN_TIMEOUT" $COMMAND; then
        log "done"
    else
        log "FAILED with status $?"
    fi
}

main() {
    if [ "${SCHEDULED_PUBLISH_ENABLED:-0}" != "1" ]; then
        log "SCHEDULED_PUBLISH_ENABLED is not 1: scheduled ideas are not published"
        while true; do sleep 86400; done
    fi
    if ! valid_interval "$INTERVAL"; then
        log "SCHEDULED_PUBLISH_INTERVAL must be a number of seconds, got '$INTERVAL'"
        exit 1
    fi
    if ! valid_interval "$RUN_TIMEOUT"; then
        log "SCHEDULED_PUBLISH_TIMEOUT must be a number of seconds, got '$RUN_TIMEOUT'"
        exit 1
    fi
    log "publishing scheduled ideas every $INTERVAL seconds"
    while true; do
        sleep "$INTERVAL"
        run_command
    done
}

# Tests source this file to reach the functions above.
if [ -z "${SCHEDULED_PUBLISH_LOOP_SOURCED:-}" ]; then
    main
fi
