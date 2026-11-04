#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Tests that every path gated behind oauth2-proxy in nginx/nginx.fullstack.conf
# also answers its bare form (no trailing slash) with an absolute redirect.
# For a prefix location such as "/admin/", nginx itself redirects "/admin" to
# "/admin/" and completes the Location header with the listen port of the
# container (8081), which is not reachable from outside. An exact-match
# location that spells out scheme and host avoids that.
# Run: sh scripts/test-nginx-bare-redirects.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CONF=${NGINX_CONF:-"$HERE/../nginx/nginx.fullstack.conf"}
failures=0

# The single-segment prefix locations ("location /name/ {") whose block holds
# an auth_request, one name per line.
GATED=$(awk '
    /^[[:space:]]*location[[:space:]]+\/[A-Za-z0-9_-]+\/[[:space:]]*\{/ {
        name = $2; gsub(/\//, "", name); current = name
    }
    /^[[:space:]]*\}/ { current = "" }
    /^[[:space:]]*auth_request[[:space:]]/ && current != "" { print current }
' "$CONF" | sort -u)

if [ -z "$GATED" ]; then
    echo "FAIL could not find any gated location in $CONF"
    exit 1
fi

for name in $GATED; do
    # shellcheck disable=SC2016  # $host is an nginx variable
    want="location = /$name { return 301 https://\$host/$name/; }"
    if grep -qxF "        $want" "$CONF"; then
        echo "ok   /$name answers its bare form with an absolute redirect"
    else
        echo "FAIL /$name has no bare redirect: expected the line '$want'"
        failures=$((failures + 1))
    fi
done

# The check above must keep covering both paths that exist today.
for name in admin staff; do
    case " $(echo "$GATED" | tr '\n' ' ') " in
        *" $name "*) echo "ok   /$name is detected as gated" ;;
        *)
            echo "FAIL /$name was not detected as gated"
            failures=$((failures + 1))
            ;;
    esac
done

if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
echo "all passed"
