#!/bin/bash
# Run the shell implementation (OLD_BIN, default ./eb-keep-logs) and the Zig
# build (TOOL_BIN) on the same invocations and compare exit code, stdout and
# stderr. A difference COMPAT.md lists as deliberate is reported and allowed;
# any other fails the run.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/differential.sh
set -u
repo_root=$(cd "$(dirname "$0")/.." && pwd)
OLD_BIN="${OLD_BIN:-${repo_root}/eb-keep-logs}"
: "${TOOL_BIN:?}"
work=$(mktemp -d "${TMPDIR:-/tmp}/ekl-diff.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
mkdir -p "${work}/logs" "${work}/bin"
printf '#!/bin/bash\nexit 0\n' > "${work}/bin/eb"
chmod +x "${work}/bin/eb"
export PATH="${work}/bin:${PATH}"

diffs=0
# Labels whose difference COMPAT.md documents.
deliberate=("no arguments")
# compare LABEL ARGS...: run both with the same arguments.
compare() {
    local label=$1; shift
    "${OLD_BIN}" "$@" > "${work}/o.out" 2> "${work}/o.err"; local oc=$?
    "${TOOL_BIN}" "$@" > "${work}/n.out" 2> "${work}/n.err"; local nc=$?
    if [ "${oc}" != "${nc}" ] || ! cmp -s "${work}/o.out" "${work}/n.out" || ! cmp -s "${work}/o.err" "${work}/n.err"; then
        local d
        for d in "${deliberate[@]}"; do
            if [ "${d}" = "${label}" ]; then
                echo "deliberate ${label}"
                return
            fi
        done
        echo "DIFF ${label}: exit ${oc} vs ${nc}"
        diff "${work}/o.out" "${work}/n.out" | sed 's/^/     out /'
        diff "${work}/o.err" "${work}/n.err" | sed 's/^/     err /'
        diffs=$((diffs + 1))
    else
        echo "same ${label}"
    fi
}

compare "no arguments"
compare "unknown command" bogus
compare "failed, too few" failed 1 Foo
compare "failed, bad status" failed x Foo "${work}/logs"
compare "failed, missing logdir" failed 1 Foo "${work}/nope"
compare "failed, success" failed 0 Foo "${work}/logs"
compare "failed, zeros are success" failed 000 Foo "${work}/logs"
compare "failed, no eb log" failed 3 Foo "${work}/logs"
compare "failed, empty tmp logdir" failed 3 Foo "${work}/logs" ""
compare "rotate, no root" rotate --compress-after 3
compare "rotate, two roots" rotate a b
compare "rotate, unknown option" rotate "${work}" --bogus
compare "rotate, missing root" rotate "${work}/nope" --compress-after 3
compare "rotate, no compress" rotate "${work}/logs"
compare "rotate, bad compress" rotate "${work}/logs" --compress-after=x
compare "rotate, delete not later" rotate "${work}/logs" --compress-after 5 --delete-after 5
compare "rotate, empty delete" rotate "${work}/logs" --compress-after 5 --delete-after ""
compare "rotate, nothing to do" rotate "${work}/logs" --compress-after 5 --delete-after 9

echo "${diffs} differences"
[ "${diffs}" -eq 0 ]
