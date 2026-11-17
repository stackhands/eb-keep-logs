#!/bin/bash
# The tutorial installs the shell script. It has to say that why and history
# are in the Zig build only, and how to build that program.
set -eu
cd "$(dirname -- "$0")/.."
page=docs/orgmode/tutorials/keep-a-failed-build-log.org
grep -F 'in the Zig build only' "$page" >/dev/null || {
    echo "the tutorial does not say why and history are in the Zig build only" >&2
    exit 1
}
grep -F 'zig build -Drelease=true' "$page" >/dev/null || {
    echo "the tutorial does not say how to build the Zig program" >&2
    exit 1
}
grep -F 'find-why-a-build-failed.org' "$page" >/dev/null || {
    echo "the tutorial does not link the why how-to" >&2
    exit 1
}
