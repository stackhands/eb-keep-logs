# shellcheck shell=bash
# Sourced by the shell tests, each of which sets fails=0 itself.
# check LABEL GOT EXPECTED prints "ok LABEL" when GOT is EXPECTED, and
# otherwise prints both to stderr and counts one more in fails. Failures
# go to stderr: zig build test shows a script's stderr, not stdout.
check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        {
            echo "FAIL $1"
            echo "     expected: $3"
            echo "     got:      $2"
        } >&2
        fails=$((fails + 1))
    fi
}
