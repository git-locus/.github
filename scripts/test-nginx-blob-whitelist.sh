#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Tests the whitelist of blob URLs in nginx/nginx.fullstack.conf: the only
# URLs nginx fetches when the API redirects an avatar request to storage.
# Run: sh scripts/test-nginx-blob-whitelist.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CONF=${NGINX_CONF:-"$HERE/../nginx/nginx.fullstack.conf"}
failures=0

# The pattern of the map entry that sets $blob_name; nginx and grep -P both
# use PCRE syntax.
# shellcheck disable=SC2016  # the $ is part of the nginx variable name
PATTERN=$(sed -n 's/^ *"~\(.*\)" \$blob_name;$/\1/p' "$CONF")
if [ -z "$PATTERN" ]; then
    echo "FAIL could not find the blob whitelist in $CONF"
    exit 1
fi

check() {
    # $1 label, $2 expected (accept or reject), $3 URL
    if printf '%s\n' "$3" | grep -qP "$PATTERN"; then got=accept; else got=reject; fi
    if [ "$got" = "$2" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: expected $2, got $got ($3)"
        failures=$((failures + 1))
    fi
}

HOST=https://locusstore.blob.core.windows.net
BLOB=$HOST/locus-media/avatars/3f2c9b1e-0d4a-4a53-9b7e-1a2b3c4d5e6f.jpg
SAS='se=2026-10-27T22%3A23%3A26Z&sp=r&sv=2026-10-06&sr=b'

check "signed avatar URL" accept "$BLOB?$SAS&sig=abcDEF123%2Bxyz%3D"
# Azure leaves / and + of the base64 signature unescaped in some cases.
check "signature with a slash" accept "$BLOB?$SAS&sig=nRW%2BBFvm/dLe8ubemF%2BOiQbD4%3D"
check "signature with a plus" accept "$BLOB?$SAS&sig=ab+cd%3D"
check "blob name with an upload suffix" accept "$HOST/locus-media/avatars/photo_1-AbC123.jpg?$SAS&sig=x"

check "no signature" reject "$BLOB"
check "empty query" reject "$BLOB?"
check "other host" reject "https://evil.example/locus-media/avatars/a.jpg?$SAS&sig=x"
check "host that only contains the Azure name" reject "https://x.blob.core.windows.net.evil.example/locus-media/avatars/a.jpg?$SAS&sig=x"
check "plain http" reject "http://locusstore.blob.core.windows.net/locus-media/avatars/a.jpg?$SAS&sig=x"
check "other container" reject "$HOST/other/avatars/a.jpg?$SAS&sig=x"
check "post pictures are not fetched this way" reject "$HOST/locus-media/posts/a.jpg?$SAS&sig=x"
check "path traversal" reject "$HOST/locus-media/avatars/../posts/a.jpg?$SAS&sig=x"
check "sub path" reject "$HOST/locus-media/avatars/dir/a.jpg?$SAS&sig=x"
check "name starting with a dot" reject "$HOST/locus-media/avatars/.hidden?$SAS&sig=x"
check "space in the query" reject "$BLOB?$SAS&sig=x y"

if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
echo "all passed"
