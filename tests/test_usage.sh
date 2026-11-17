#!/bin/bash
# Installed software with XALT and Lmod usage hits.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_usage.sh
set -u

tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac

fails=0
check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        {
            echo "FAIL $1"
            echo "expected: $3"
            echo "got:      $2"
        } >&2
        fails=$((fails + 1))
    fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-usage.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
software="${work}/software"
modules="${work}/modules"
for module in Foo/1.0 Bar/2.0 Old/1.0 Never/3.0; do
    mkdir -p "${software}/${module}"
done
mkdir -p "${modules}/Foo" "${modules}/Bar"
touch "${modules}/Foo/1.0.lua" "${modules}/Bar/2.0.lua"

cat > "${work}/xalt.json" <<EOF
{"userT":{"user":"a","exec_path":"${software}/Foo/1.0/bin/foo","start_time":200}}
{"userT":{"user":"b","exec_path":"${software}/Old/1.0/bin/old","start_time":"50"}}
{"package_path":"${software}/Never/3.0"}
EOF
cat > "${work}/lmod.log" <<EOF
user=c module=Bar/2.0 path=${modules}/Bar/2.0.lua host=n1 time=300
user=d module=Outside/1.0 path=/other/Outside/1.0.lua host=n2 time=400
user=e module=Never/3.0 path=${modules}/Never/3.0.lua host=n3 time=nan
EOF
cat > "${work}/mixed.log" <<EOF
user=c module=Bar/2.0 path=${modules}/Bar/2.0.lua host=n1 time=300
{"userT":{"user":"a","exec_path":"${software}/Foo/1.0/bin/foo","start_time":200}}
user=d module=Outside/1.0 path=/other/Outside/1.0.lua host=n2 time=400
{"userT":{"user":"b","exec_path":"${software}/Old/1.0/bin/old","start_time":"50"}}
{"package_path":"${software}/Never/3.0"}
EOF

mixed=$("${tool}" usage --software "${software}" --modules "${modules}" --active \
    "${work}/mixed.log")
check "interleaved Lmod and XALT share one scan" "${mixed}" $'Bar/2.0\nFoo/1.0\nNever/3.0\nOld/1.0'

active=$("${tool}" usage --software "${software}" --modules "${modules}" --active \
    "${work}/xalt.json" "${work}/lmod.log")
check "active is a sorted Name/Version listing" "${active}" $'Bar/2.0\nFoo/1.0\nNever/3.0\nOld/1.0'

relative=$(cd "${work}" && "${tool}" usage --software software --modules modules \
    --since 100 --active xalt.json lmod.log)
check "relative roots match absolute record paths" "${relative}" $'Bar/2.0\nFoo/1.0'

ln -s software "${work}/software-link"
ln -s modules "${work}/modules-link"
linked=$("${tool}" usage --software "${work}/software-link" --modules "${work}/modules-link" \
    --since 100 --active "${work}/xalt.json" "${work}/lmod.log")
check "linked roots match canonical record paths" "${linked}" $'Bar/2.0\nFoo/1.0'

active_since=$("${tool}" usage --software="${software}" --modules="${modules}" \
    --since 100 --active "${work}/xalt.json" "${work}/lmod.log")
check "since filters old and timeless records" "${active_since}" $'Bar/2.0\nFoo/1.0'

unused=$("${tool}" usage --software "${software}" --modules "${modules}" \
    --since=100 --unused "${work}/xalt.json" "${work}/lmod.log")
check "unused names retirement candidates" "${unused}" $'Never/3.0\nOld/1.0'

all=$("${tool}" usage --software "${software}" --modules "${modules}" \
    --since=100 "${work}/xalt.json" "${work}/lmod.log")
check "default report marks active" "$(grep -c '^active ' <<<"${all}")" "2"
check "default report marks unused" "$(grep -c '^unused ' <<<"${all}")" "2"

json=$("${tool}" usage --software "${software}" --modules "${modules}" \
    --since=100 --active --json "${work}/xalt.json" "${work}/lmod.log")
check "json report" "$(python3 -c '
import json, sys
o = json.load(sys.stdin)
assert o["schema_version"] == 1 and o["kind"] == "usage"
assert o["selection"] == "active" and o["since"] == "100"
assert [p["module"] for p in o["packages"]] == ["Bar/2.0", "Foo/1.0"]
assert all(p["active"] and p["hits"] == 1 for p in o["packages"])
print("ok")
' <<<"${json}")" "ok"

v3=$("${tool}" usage \
    --software tests/fixtures/xalt-software \
    --modules tests/fixtures/xalt-software \
    --active tests/fixtures/xalt-v3.log)
check "XALT V:3 chunks feed usage" "${v3}" "GROMACS/2024"

"${tool}" usage --software "${software}" --modules "${modules}" \
    --unused --active "${work}/lmod.log" >/dev/null 2>"${work}/err"
check "selection is exclusive" "$?" "2"
check "selection refusal" "$(cat "${work}/err")" \
    "eb-keep-logs: usage takes --unused or --active, not both"

echo "${fails} failed"
[ "${fails}" -eq 0 ]
