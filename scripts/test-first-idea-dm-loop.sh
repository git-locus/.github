#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Tests for first-idea-dm-loop.sh. Run: sh scripts/test-first-idea-dm-loop.sh
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

# shellcheck source=first-idea-dm-loop.sh
FIRST_IDEA_DM_LOOP_SOURCED=1 . "$HERE/first-idea-dm-loop.sh"
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
check "the command defaults to send_first_idea_dms" \
    "$(FIRST_IDEA_DM_LOOP_SOURCED=1 sh -c '. "$1"; echo "$COMMAND"' sh "$HERE/first-idea-dm-loop.sh")" \
    "python manage.py send_first_idea_dms"
check "the interval defaults to five minutes" \
    "$(FIRST_IDEA_DM_LOOP_SOURCED=1 sh -c '. "$1"; echo "$INTERVAL"' sh "$HERE/first-idea-dm-loop.sh")" \
    300

# --- main -------------------------------------------------------------------
out=$(FIRST_IDEA_DM_INTERVAL=abc FIRST_IDEA_DM_ENABLED=1 sh "$HERE/first-idea-dm-loop.sh" 2>&1)
check "a bad interval exits 1" "$?" 1
case "$out" in
    *"must be a number of seconds"*) check "a bad interval says why" ok ok ;;
    *) check "a bad interval says why" "$out" "must be a number of seconds" ;;
esac

# Off by default: it must keep running without running the command.
sentinel="$(mktemp -d)/ran"
FIRST_IDEA_DM_COMMAND="touch $sentinel" sh "$HERE/first-idea-dm-loop.sh" >/dev/null 2>&1 &
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
PATH="$bin:$PATH" FIRST_IDEA_DM_ENABLED=1 FIRST_IDEA_DM_INTERVAL=120 \
    FIRST_IDEA_DM_COMMAND="touch $sentinel" \
    sh "$HERE/first-idea-dm-loop.sh" >/dev/null 2>&1 &
pid=$!
"$real_sleep" 2.5
kill "$pid" 2>/dev/null
check "on: sleeps the interval first" "$(head -n 1 "$sleeplog")" 120
check "on: runs the command after sleeping" \
    "$([ -e "$sentinel" ] && echo ran || echo idle)" ran

# A failing run must not stop the loop: it sleeps again.
rm -f "$sleeplog"
PATH="$bin:$PATH" FIRST_IDEA_DM_ENABLED=1 FIRST_IDEA_DM_INTERVAL=120 \
    FIRST_IDEA_DM_COMMAND="false" \
    sh "$HERE/first-idea-dm-loop.sh" >/dev/null 2>&1 &
pid=$!
"$real_sleep" 3.5
kill "$pid" 2>/dev/null
check "a failing run does not stop the loop" \
    "$([ "$(wc -l < "$sleeplog")" -ge 2 ] && echo looping || echo stopped)" looping

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
