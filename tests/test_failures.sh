#!/bin/bash
# Tests for opt-in recipe and date filtering in failures, why, and history:
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_failures.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac
cd "${repo_root}" || exit 1
logs=tests/fixtures/build-logs

fails=0
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

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-failures.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

# failures: all failed builds across the fixture corpus.
out=$("${tool}" failures --root "${logs}")
check "failures: header count" "$(printf '%s\n' "${out}" | head -n 1)" \
    "${logs}: 8 failed builds in 7 runs"
check "failures: includes fetch and test steps" "$(printf '%s\n' "${out}" | awk 'NR >= 4 { print $3 }' | tr '\n' ' ')" \
    "fetch patch - configure build build sanitycheck test "

# Date filtering: exact timestamp bounds and YYYY-MM-DD / YYYYMMDD bounds.
out=$("${tool}" failures --root "${logs}" --since 20261117_040615 --until 20261117_041222)
check "failures: timestamp range header" "$(printf '%s\n' "${out}" | head -n 1)" \
    "${logs}: 4 failed builds in 3 runs"
check "failures: timestamp range runs" "$(printf '%s\n' "${out}" | awk 'NR >= 4 { print $1 }' | tr '\n' ' ')" \
    "20261117_040615 20261117_040928 20261117_041222 20261117_041222 "

# Recipe filtering: GCCcore-13.3.0 vs module name hello/2.12.1-GCCcore-13.3.0.
out=$("${tool}" failures --root "${logs}" --package hello-2.12.1-GCCcore-13.3.0)
check "failures: package filter header" "$(printf '%s\n' "${out}" | head -n 1)" \
    "${logs}: 1 failed build in 1 run"
check "failures: package filter row" "$(printf '%s\n' "${out}" | tail -n 1)" \
    "20261117_041222  sapphirerapids  sanitycheck  2m54s     hello-2.12.1-GCCcore-13.3.0"
check "failures: module slash form matches" \
    "$("${tool}" failures --root "${logs}" --package hello/2.12.1-GCCcore-13.3.0)" "${out}"

# Target + date filtering with zero matching failures.
check "failures: target generic has 0 failures" \
    "$("${tool}" failures --root "${logs}" --target generic)" \
    "${logs}: 0 failed builds in 0 runs"
check "failures: future date range has 0 failures" \
    "$("${tool}" failures --root "${logs}" --since 2026-11-18)" \
    "${logs}: 0 failed builds in 0 runs"

# Synthetic multi-recipe tree: filter by recipe or date across different packages.
mkdir -p \
    "${work}/tree/20261110_010000/zen4" \
    "${work}/tree/20261112_120000/zen4" \
    "${work}/tree/20261115_080000/zen4"
printf '== FAILED: Installation ended unsuccessfully: bad configure (took 10 secs)\n' \
    > "${work}/tree/20261110_010000/zen4/OpenMPI-5.0.stdout.log"
printf '== COMPLETED: Installation ended successfully (took 5 secs)\n' \
    > "${work}/tree/20261112_120000/zen4/OpenMPI-5.0.stdout.log"
printf '== FAILED: Installation ended unsuccessfully: bad test (took 20 secs)\n' \
    > "${work}/tree/20261112_120000/zen4/GROMACS-2024.1.stdout.log"
printf '== FAILED: Installation ended unsuccessfully: bad build (took 30 secs)\n' \
    > "${work}/tree/20261115_080000/zen4/OpenMPI-5.0.stdout.log"

check "failures: multi-recipe date filter" \
    "$("${tool}" failures --root "${work}/tree" --since 20261111 --until 2026-11-14 | awk 'NR >= 4 { print $1, $5 }')" \
    "20261112_120000 GROMACS-2024.1"
check "failures: multi-recipe package filter" \
    "$("${tool}" failures --root "${work}/tree" --package OpenMPI | awk 'NR >= 4 { print $1, $5 }' | tr '\n' ';')" \
    "20261110_010000 OpenMPI-5.0;20261115_080000 OpenMPI-5.0;"

# failures --json structure.
fjson=$("${tool}" failures --root "${work}/tree" --package OpenMPI --since 2026-11-12 --json)
check "failures --json fields" "$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["schema_version"] == 1 and d["kind"] == "failures"
assert d["package"] == "OpenMPI" and d["since"] == "2026-11-12" and d["until"] is None
assert d["counts"] == {"runs": 1, "failed": 1}
assert len(d["failures"]) == 1
f = d["failures"][0]
assert f["run"] == "20261115_080000" and f["target"] == "zen4" and f["name"] == "OpenMPI-5.0"
assert f["duration_s"] == 30
print("ok")
' <<< "${fjson}")" "ok"

# why opt-in filters: --package, --since, --until.
why_pkg=$("${tool}" why --root "${logs}" 20261117_041222 --package hello-2.12.1-GCCcore-14.2.0 --json)
check "why --package filters failures and counts" "$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["counts"] == {"success": 1, "failed": 1, "unknown": 0}
assert len(d["failures"]) == 1
assert d["failures"][0]["name"] == "hello-2.12.1-GCCcore-14.2.0"
print("ok")
' <<< "${why_pkg}")" "ok"

why_date=$("${tool}" why --root "${logs}" --until 20261117_040615)
check "why --until picks newest run in range" "$(printf '%s\n' "${why_date}" | head -n 1)" \
    "${logs}/20261117_040615: 1 failed build of 1"

# history opt-in filters: --since, --until, --failed.
hist_f=$("${tool}" history hello --root "${logs}" --since 20261117_040615 --until 20261117_042207 --failed)
check "history --since/--until/--failed header" "$(printf '%s\n' "${hist_f}" | head -n 1)" \
    "hello: 4 builds under ${logs}: 0 succeeded, 4 failed"
check "history --since/--until/--failed rows" "$(printf '%s\n' "${hist_f}" | awk 'NR >= 4 { print $1, $3 }' | tr '\n' ';')" \
    "20261117_040615 failed;20261117_040928 failed;20261117_041222 failed;20261117_041222 failed;"

# Refusals for invalid filter arguments.
refused() {
    local label=$1 message=$2; shift 2
    "${tool}" "$@" > /dev/null 2> "${work}/err"
    check "refused, ${label}: exit 2" "$?" "2"
    check "refused, ${label}: message" "$(cat "${work}/err")" "eb-keep-logs: ${message}"
}

refused "failures bad date" "--since needs YYYY-MM-DD, YYYYMMDD, or YYYYMMDD_HHMMSS" failures --root "${logs}" --since 2026-02-29
refused "failures inverted range" "--until must not be earlier than --since" failures --root "${logs}" --since 2026-11-18 --until 2026-11-17
refused "failures empty package" "--package needs a package" failures --root "${logs}" --package=
refused "failures positional arg" "failures takes no positional argument, got 'extra'" failures extra
refused "why RUN with --since" "why takes RUN or --since/--until, not both" why "${logs}/20261117_040615" --since 2026-11-17
refused "why date range no match" "no run under ${logs} matches the date range" why --root "${logs}" --since 2026-11-18
refused "history inverted range" "--until must not be earlier than --since" history hello --root "${logs}" --since 2026-11-18 --until 2026-11-17

"${tool}" failures --help > "${work}/fhelp" 2> "${work}/ferr"
check "failures --help exit 0" "$?" "0"
check "failures --help stderr empty" "$(cat "${work}/ferr")" ""
check "failures --help names YYYYMMDD_HHMMSS" "$(grep -c 'YYYYMMDD_HHMMSS' "${work}/fhelp")" "1"

if [ "${fails}" -ne 0 ]; then echo "${fails} failed"; exit 1; fi
echo "all passed"
