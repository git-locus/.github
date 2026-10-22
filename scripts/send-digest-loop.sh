#!/bin/sh
# Daily digest scheduler, run by supervisord (program `digest`) next to the
# API. Once a day at DIGEST_RUN_AT_UTC it runs `manage.py send_digest`, which
# e-mails each person what they missed (at most one digest per person per
# calendar day, so an extra run is harmless).
#
# Off unless DIGEST_ENABLED=1: the process then just sleeps, so supervisord
# has nothing to restart. The time is plain UTC arithmetic, no time zone
# database needed: 06:30 UTC is 07:30 (winter) or 08:30 (summer) in
# Europe/Rome. A container that restarts across the run time waits for the
# next day; the next digest then covers the missed day too (the window
# reaches back to the previous digest, 48 hours at most).
set -eu

RUN_AT="${DIGEST_RUN_AT_UTC:-06:30}"
COMMAND="${DIGEST_COMMAND:-python manage.py send_digest}"

log() {
    echo "[send-digest-loop] $*"
}

valid_run_at() {
    case "$1" in
        [01][0-9]:[0-5][0-9] | 2[0-3]:[0-5][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

# Seconds to sleep from $1 (seconds since midnight UTC) until the next
# RUN_AT. Exactly at RUN_AT it answers a full day, not 0.
seconds_until_next_run() {
    # The leading 1 keeps "08" and "09" from being read as octal.
    target=$(( (1${RUN_AT%%:*} - 100) * 3600 + (1${RUN_AT##*:} - 100) * 60 ))
    wait=$(( (target - $1 + 86400) % 86400 ))
    [ "$wait" -eq 0 ] && wait=86400
    echo "$wait"
}

# A failing run is logged, never fatal: tomorrow's run must still happen.
run_digest() {
    log "running: $COMMAND"
    # shellcheck disable=SC2086  # the command is meant to be word-split
    if $COMMAND; then
        log "done"
    else
        log "FAILED with status $?"
    fi
}

main() {
    if [ "${DIGEST_ENABLED:-0}" != "1" ]; then
        log "DIGEST_ENABLED is not 1: the daily digest is off"
        while true; do sleep 86400; done
    fi
    if ! valid_run_at "$RUN_AT"; then
        log "DIGEST_RUN_AT_UTC must be HH:MM (24 hours), got '$RUN_AT'"
        exit 1
    fi
    log "daily digest on, at $RUN_AT UTC"
    while true; do
        sleep "$(seconds_until_next_run $(( $(date -u +%s) % 86400 )))"
        run_digest
    done
}

# Tests source this file to reach the functions above.
if [ -z "${DIGEST_LOOP_SOURCED:-}" ]; then
    main
fi
