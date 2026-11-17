#!/bin/bash
# Who loaded a module, from Lmod's ModuleUsageTracking lines.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_loads.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac

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

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-loads.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
cat > "${work}/moduleUsage.log" <<'EOF'
Nov 17 12:00:01 login01 ModuleUsageTracking: user=alice jobid=8102 module=GROMACS/2024.1 path=/cvmfs/g.lua host=login01 time=1731840001.250000
this line is not a record
user=bob module=GCC/13.2.0 path=/cvmfs/host=not-a-field.lua host=login02 time=1731840002.000000
user=cara jobid=8103 module=GROMACS/2024.1 path=/other.lua host=login01 time=1731840099.5
user=dana module=GROMACS/2024.1 path=/missing-host.lua time=1
EOF

out=$("${tool}" loads --module GROMACS/2024.1 "${work}/moduleUsage.log")
check "loads keep job identifiers" "${out}" "user=alice jobid=8102 host=login01 time=1731840001.250000 path=/cvmfs/g.lua
user=cara jobid=8103 host=login01 time=1731840099.5 path=/other.lua"
check "joined module flag" "$("${tool}" loads --module=GCC/13.2.0 "${work}/moduleUsage.log")" "user=bob host=login02 time=1731840002.000000 path=/cvmfs/host=not-a-field.lua"
check "user and since filters" "$("${tool}" loads --module GROMACS/2024.1 --user=cara --since 1731840050 "${work}/moduleUsage.log")" \
    "user=cara jobid=8103 host=login01 time=1731840099.5 path=/other.lua"
check "job filter" "$("${tool}" loads --module GROMACS/2024.1 --jobid 8102 "${work}/moduleUsage.log")" \
    "user=alice jobid=8102 host=login01 time=1731840001.250000 path=/cvmfs/g.lua"
json=$("${tool}" loads --module GROMACS/2024.1 --user alice --since=1731840000 --json "${work}/moduleUsage.log")
check "json filters and job identifier" "$(python3 -c '
import json, sys
o = json.load(sys.stdin)
assert o["schema_version"] == 1 and o["kind"] == "loads"
assert o["module"] == "GROMACS/2024.1"
assert o["loads"][0]["jobid"] == "8102"
print("ok")
' <<<"${json}")" "ok"
check "none" "$("${tool}" loads --module Missing/1.0 "${work}/moduleUsage.log")" "no load of Missing/1.0"
"${tool}" loads "${work}/moduleUsage.log" >/dev/null 2>"${work}/err"
check "module is required" "$?" "2"
check "the refusal names the flag" "$(cat "${work}/err")" "eb-keep-logs: loads needs --module"
page=$(cat "${repo_root}/docs/orgmode/howto/who-loaded-a-module.org")
check "how-to names the command" "$(grep -c 'loads --module' <<< "${page}")" "2"
check "how-to names the empty answer" "$(grep -c 'no load of' <<< "${page}")" "1"

echo "${fails} failed"
[ "${fails}" -eq 0 ]
