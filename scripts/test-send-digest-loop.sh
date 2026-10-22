#!/bin/sh
# Tests for send-digest-loop.sh. Run: sh scripts/test-send-digest-loop.sh
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

load() {
    # shellcheck source=send-digest-loop.sh
    DIGEST_LOOP_SOURCED=1 DIGEST_RUN_AT_UTC="$1" . "$HERE/send-digest-loop.sh"
    # shellcheck disable=SC2034  # read by the functions under test
    RUN_AT="$1"
    # The script under test sets -e; the checks below need to see failures.
    set +e
}

# --- seconds_until_next_run ---------------------------------------------
load 06:30
check "midnight waits until 06:30" "$(seconds_until_next_run 0)" 23400
check "one second before waits one second" "$(seconds_until_next_run 23399)" 1
check "exactly at run time waits a day" "$(seconds_until_next_run 23400)" 86400
check "after run time waits for tomorrow" "$(seconds_until_next_run 80000)" 29800

load 08:09
check "08:09 is not read as octal" "$(seconds_until_next_run 0)" 29340
load 23:59
check "late run time" "$(seconds_until_next_run 0)" 86340
load 00:00
check "midnight run time at 01:00" "$(seconds_until_next_run 3600)" 82800

# --- valid_run_at -----------------------------------------------------------
for good in 00:00 06:30 12:05 19:59 23:59; do
    valid_run_at "$good"; check "accepts $good" "$?" 0
done
for bad in "" 6:30 24:00 07:60 0630 06:30:00 ab:cd 06-30 " 06:30"; do
    valid_run_at "$bad"; check "rejects '$bad'" "$?" 1
done

# --- run_digest ---------------------------------------------------------------
# shellcheck disable=SC2034  # COMMAND is read by run_digest
COMMAND="true"
out=$(run_digest)
case "$out" in
    *"] done") check "a good run logs done" ok ok ;;
    *) check "a good run logs done" "$out" "...] done" ;;
esac
# shellcheck disable=SC2034
COMMAND="false"
out=$(run_digest); check "a failing run returns" "$?" 0
case "$out" in
    *FAILED*) check "a failing run is logged" ok ok ;;
    *) check "a failing run is logged" "$out" "FAILED" ;;
esac
# shellcheck disable=SC2034
COMMAND="echo --flag value"
out=$(run_digest)
case "$out" in
    *"--flag value"*) check "the command keeps its arguments" ok ok ;;
    *) check "the command keeps its arguments" "$out" "--flag value" ;;
esac

# --- main -------------------------------------------------------------------
out=$(DIGEST_RUN_AT_UTC=25:99 DIGEST_ENABLED=1 sh "$HERE/send-digest-loop.sh" 2>&1)
check "a bad time exits 1" "$?" 1
case "$out" in
    *"must be HH:MM"*) check "a bad time says why" ok ok ;;
    *) check "a bad time says why" "$out" "must be HH:MM" ;;
esac

# Off by default: it must keep running without sending anything.
sentinel="$(mktemp -d)/ran"
DIGEST_COMMAND="touch $sentinel" sh "$HERE/send-digest-loop.sh" >/dev/null 2>&1 &
pid=$!
sleep 1
if kill -0 "$pid" 2>/dev/null; then check "off: stays alive" ok ok; else check "off: stays alive" dead alive; fi
kill "$pid" 2>/dev/null
check "off: runs nothing" "$([ -e "$sentinel" ] && echo ran || echo idle)" idle

# On: waits, then runs the command. A fake `sleep` logs how long it was asked
# to wait and returns after a second.
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
PATH="$bin:$PATH" DIGEST_ENABLED=1 DIGEST_COMMAND="touch $sentinel" \
    sh "$HERE/send-digest-loop.sh" >/dev/null 2>&1 &
pid=$!
"$real_sleep" 2.5
kill "$pid" 2>/dev/null
first=$(head -n 1 "$sleeplog")
check "on: sleeps a bounded time first" \
    "$([ "${first:-0}" -ge 1 ] && [ "${first:-0}" -le 86400 ] && echo yes || echo no)" yes
check "on: runs the command after sleeping" \
    "$([ -e "$sentinel" ] && echo ran || echo idle)" ran

if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
echo "all passed"
