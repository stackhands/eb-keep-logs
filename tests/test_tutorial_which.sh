#!/bin/bash
# The tutorial has to say how to build the program, and link the how-to of
# why.
set -eu
cd "$(dirname -- "$0")/.."
page=docs/orgmode/tutorials/keep-a-failed-build-log.org
grep -F 'zig build -Drelease=true' "$page" >/dev/null || {
    echo "the tutorial does not say how to build the Zig program" >&2
    exit 1
}
grep -F 'find-why-a-build-failed.org' "$page" >/dev/null || {
    echo "the tutorial does not link the why how-to" >&2
    exit 1
}
