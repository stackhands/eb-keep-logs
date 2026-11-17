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
Nov 17 12:00:01 login01 ModuleUsageTracking: user=alice module=GROMACS/2024.1 path=/cvmfs/g.lua host=login01 time=1731840001.250000
this line is not a record
user=bob module=GCC/13.2.0 path=/cvmfs/host=not-a-field.lua host=login02 time=1731840002.000000
user=cara module=GROMACS/2024.1 path=/other.lua host=login01 time=1731840099.5
user=dana module=GROMACS/2024.1 path=/missing-host.lua time=1
EOF

out=$("${tool}" loads --module GROMACS/2024.1 "${work}/moduleUsage.log")
check "loads of one module" "${out}" "user=alice host=login01 time=1731840001.250000 path=/cvmfs/g.lua
user=cara host=login01 time=1731840099.5 path=/other.lua"
check "joined module flag" "$("${tool}" loads --module=GCC/13.2.0 "${work}/moduleUsage.log")" "user=bob host=login02 time=1731840002.000000 path=/cvmfs/host=not-a-field.lua"
check "none" "$("${tool}" loads --module Missing/1.0 "${work}/moduleUsage.log")" "no load of Missing/1.0"
gzip -c "${work}/moduleUsage.log" > "${work}/moduleUsage.log.gz"
check "gzip log" "$("${tool}" loads --gzip --module=GCC/13.2.0 "${work}/moduleUsage.log.gz")" "user=bob host=login02 time=1731840002.000000 path=/cvmfs/host=not-a-field.lua"
check "gzip is opt in" "$("${tool}" loads --module=GCC/13.2.0 "${work}/moduleUsage.log.gz")" "no load of GCC/13.2.0"
cp "${work}/moduleUsage.log.gz" "${work}/moduleUsage.bin"
check "gzip needs the suffix" "$("${tool}" loads --gzip --module=GCC/13.2.0 "${work}/moduleUsage.bin")" "no load of GCC/13.2.0"
printf 'not gzip\n' > "${work}/bad.log.gz"
"${tool}" loads --gzip --module=GCC/13.2.0 "${work}/bad.log.gz" >/dev/null 2>"${work}/gzip-err"
check "bad gzip is refused" "$?" "2"
check "bad gzip is named" "$(cat "${work}/gzip-err")" "eb-keep-logs: cannot read ${work}/bad.log.gz: BadGzip"
"${tool}" loads "${work}/moduleUsage.log" >/dev/null 2>"${work}/err"
check "module is required" "$?" "2"
check "the refusal names the flag" "$(cat "${work}/err")" "eb-keep-logs: loads needs --module"
page=$(cat "${repo_root}/docs/orgmode/howto/who-loaded-a-module.org")
check "how-to names the command" "$(grep -c 'loads --module' <<< "${page}")" "1"
check "how-to names the empty answer" "$(grep -c 'no load of' <<< "${page}")" "1"

echo "${fails} failed"
[ "${fails}" -eq 0 ]
