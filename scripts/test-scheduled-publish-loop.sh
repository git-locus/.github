#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Tests for scheduled-publish-loop.sh. Run: sh scripts/test-scheduled-publish-loop.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
failures=0

check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: expected '$3', got '$2'"
        failures=$((failures + 1))
    fi
}

# shellcheck source=scheduled-publish-loop.sh
SCHEDULED_PUBLISH_LOOP_SOURCED=1 . "$HERE/scheduled-publish-loop.sh"
# The script under test sets -e; the checks below need to see failures.
set +e

# --- valid_interval -----------------------------------------------------------
for good in 1 60 300 86400; do
    valid_interval "$good"; check "accepts $good" "$?" 0
done
for bad in "" 0 -5 1.5 5m ab " 300"; do
    valid_interval "$bad"; check "rejects '$bad'" "$?" 1
done

# --- run_command -------------------------------------------------------------
# shellcheck disable=SC2034  # COMMAND is read by run_command
COMMAND="echo --flag value"
out=$(run_command)
case "$out" in
    *"--flag value"*"] done") check "the command runs with its arguments" ok ok ;;
    *) check "the command runs with its arguments" "$out" "--flag value ... done" ;;
esac
# shellcheck disable=SC2034
COMMAND="false"
out=$(run_command); check "a failing run returns" "$?" 0
case "$out" in
    *FAILED*) check "a failing run is logged" ok ok ;;
    *) check "a failing run is logged" "$out" "FAILED" ;;
esac
check "the command defaults to publish_scheduled" \
    "$(SCHEDULED_PUBLISH_LOOP_SOURCED=1 sh -c '. "$1"; echo "$COMMAND"' sh "$HERE/scheduled-publish-loop.sh")" \
    "python manage.py publish_scheduled"
check "the interval defaults to a minute" \
    "$(SCHEDULED_PUBLISH_LOOP_SOURCED=1 sh -c '. "$1"; echo "$INTERVAL"' sh "$HERE/scheduled-publish-loop.sh")" \
    60

# A run that hangs is cut, and logged as a failure.
# shellcheck disable=SC2034
COMMAND="sleep 5"
# shellcheck disable=SC2034
RUN_TIMEOUT=1
started=$(date +%s)
out=$(run_command)
check "a hanging run is cut" "$(( $(date +%s) - started < 4 ))" 1
case "$out" in
    *FAILED*) check "a hanging run is logged" ok ok ;;
    *) check "a hanging run is logged" "$out" "FAILED" ;;
esac
check "the timeout defaults to five minutes" \
    "$(SCHEDULED_PUBLISH_LOOP_SOURCED=1 sh -c '. "$1"; echo "$RUN_TIMEOUT"' sh "$HERE/scheduled-publish-loop.sh")" \
    300

# --- main -------------------------------------------------------------------
out=$(SCHEDULED_PUBLISH_INTERVAL=abc SCHEDULED_PUBLISH_ENABLED=1 sh "$HERE/scheduled-publish-loop.sh" 2>&1)
check "a bad interval exits 1" "$?" 1
case "$out" in
    *"must be a number of seconds"*) check "a bad interval says why" ok ok ;;
    *) check "a bad interval says why" "$out" "must be a number of seconds" ;;
esac

# Off by default: it must keep running without running the command.
sentinel="$(mktemp -d)/ran"
SCHEDULED_PUBLISH_COMMAND="touch $sentinel" sh "$HERE/scheduled-publish-loop.sh" >/dev/null 2>&1 &
pid=$!
sleep 1
if kill -0 "$pid" 2>/dev/null; then check "off: stays alive" ok ok; else check "off: stays alive" dead alive; fi
kill "$pid" 2>/dev/null
check "off: runs nothing" "$([ -e "$sentinel" ] && echo ran || echo idle)" idle

# On: sleeps the interval, then runs the command. A fake `sleep` logs how long
# it was asked to wait and returns after a second.
real_sleep=$(command -v sleep)
bin=$(mktemp -d)
sleeplog="$bin/sleeps"
cat > "$bin/sleep" <<FAKE
#!/bin/sh
echo "\$1" >> "$sleeplog"
exec "$real_sleep" 1
FAKE
chmod +x "$bin/sleep"
sentinel="$bin/ran"
PATH="$bin:$PATH" SCHEDULED_PUBLISH_ENABLED=1 SCHEDULED_PUBLISH_INTERVAL=120 \
    SCHEDULED_PUBLISH_COMMAND="touch $sentinel" \
    sh "$HERE/scheduled-publish-loop.sh" >/dev/null 2>&1 &
pid=$!
"$real_sleep" 2.5
kill "$pid" 2>/dev/null
check "on: sleeps the interval first" "$(head -n 1 "$sleeplog")" 120
check "on: runs the command after sleeping" \
    "$([ -e "$sentinel" ] && echo ran || echo idle)" ran

# A failing run must not stop the loop: it sleeps again.
rm -f "$sleeplog"
PATH="$bin:$PATH" SCHEDULED_PUBLISH_ENABLED=1 SCHEDULED_PUBLISH_INTERVAL=120 \
    SCHEDULED_PUBLISH_COMMAND="false" \
    sh "$HERE/scheduled-publish-loop.sh" >/dev/null 2>&1 &
pid=$!
"$real_sleep" 3.5
kill "$pid" 2>/dev/null
check "a failing run does not stop the loop" \
    "$([ "$(wc -l < "$sleeplog")" -ge 2 ] && echo looping || echo stopped)" looping

out=$(SCHEDULED_PUBLISH_TIMEOUT=abc SCHEDULED_PUBLISH_ENABLED=1 sh "$HERE/scheduled-publish-loop.sh" 2>&1)
check "a bad timeout exits 1" "$?" 1

# Two runs never overlap: a run that outlasts the interval is finished before
# the next one starts.
rm -f "$sleeplog"
runlog="$bin/runs"
cat > "$bin/slow" <<SLOW
#!/bin/sh
echo start >> "$runlog"
"$real_sleep" 2
echo end >> "$runlog"
SLOW
chmod +x "$bin/slow"
PATH="$bin:$PATH" SCHEDULED_PUBLISH_ENABLED=1 SCHEDULED_PUBLISH_INTERVAL=1 \
    SCHEDULED_PUBLISH_COMMAND="$bin/slow" \
    sh "$HERE/scheduled-publish-loop.sh" >/dev/null 2>&1 &
pid=$!
"$real_sleep" 6
kill "$pid" 2>/dev/null
"$real_sleep" 2.5
runs=$(awk 'NR % 2 == 1 && $1 != "start" {bad=1} NR % 2 == 0 && $1 != "end" {bad=1} END {print bad ? "overlap" : "sequential"}' "$runlog")
check "runs do not overlap" "$runs" sequential
check "more than one run happened" \
    "$([ "$(grep -c start "$runlog")" -ge 2 ] && echo yes || echo no)" yes

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
