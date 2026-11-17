#!/bin/bash
# Assert selected existing command outputs stay byte-identical.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_output_stability.sh
set -u

tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-stability.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
mkdir -p "${work}/logs" "${work}/empty"

expect() {
    local label=$1 expected_status=$2 expected_out=$3 expected_err=$4
    shift 4
    "$@" > "${work}/out" 2> "${work}/err"
    status=$?
    if [ "${status}" -ne "${expected_status}" ]; then
        echo "FAIL ${label}: status ${status} != ${expected_status}" >&2
        return 1
    fi
    printf '%s' "${expected_out}" > "${work}/exp.out"
    printf '%s' "${expected_err}" > "${work}/exp.err"
    if ! /usr/bin/cmp -s "${work}/exp.out" "${work}/out"; then
        echo "FAIL ${label}: stdout differs" >&2
        /usr/bin/diff -u "${work}/exp.out" "${work}/out" >&2 || true
        return 1
    fi
    if ! /usr/bin/cmp -s "${work}/exp.err" "${work}/err"; then
        echo "FAIL ${label}: stderr differs" >&2
        /usr/bin/diff -u "${work}/exp.err" "${work}/err" >&2 || true
        return 1
    fi
    echo "ok   ${label}"
}

(
    cd "${work}" || exit 1
    expect "failed status 0 no-op" 0 "" "" "${tool}" failed 0 Foo logs
    expect "rotate empty tree" 0 "eb-keep-logs rotate: 0 files compressed, 0 runs deleted under logs
" "" "${tool}" rotate logs --compress-after 5 --delete-after 9
    PATH="${work}/empty" expect "failed no eb on PATH" 0 "No EasyBuild log to keep for Foo: eb is not on PATH.
" "" "${tool}" failed 3 Foo logs
)
