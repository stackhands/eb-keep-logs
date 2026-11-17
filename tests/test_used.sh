#!/bin/bash
# Uses under an install prefix, from XALT and Lmod records.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_used.sh
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
            echo "expected: $3"
            echo "got:      $2"
        } >&2
        fails=$((fails + 1))
    fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-used.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
prefix="/opt/install/pkg-1.0"

cat > "${work}/xalt.json" << EOF
{"userT":{"user":"faheymr","exec_path":"/${prefix#/}/bin/hello","syshost":"n1","start_time":"100"}}
{"userT":{"user":"ada","exec_path":"/usr/bin/python","syshost":"n2","start_time":"50"},"libA":[["/${prefix#/}/lib/libfoo.so","0"]]}
{"resultT":{"exec_path":"/${prefix#/}/bin/wrapped","build_user":"bob","build_epoch":"200"},"linkA":[["/${prefix#/}/lib/liblink.so","0"]]}
{"package_path":"/${prefix#/}/extra/R/bar","package_name":"bar"}
EOF

out=$("${tool}" used --prefix "${prefix}" "${work}/xalt.json")
check "run under prefix" "$(grep -cE ' kind=run ' <<< "${out}")" "1"
check "run-lib from libA" "$(grep -c 'kind=run-lib' <<< "${out}")" "1"
check "link from resultT" "$(grep -c 'path=.*/bin/wrapped kind=link' <<< "${out}")" "1"
check "link from linkA" "$(grep -c 'liblink.so kind=link' <<< "${out}")" "1"
check "pkg package_path" "$(grep -c 'kind=pkg' <<< "${out}")" "1"
check "exec outside prefix is not run" "$(grep -c '/usr/bin/python' <<< "${out}" || true)" "0"
check "neighbour prefix absent" "$(grep -c 'install-other' <<< "${out}" || true)" "0"

cat > "${work}/moduleUsage.log" << EOF
user=alice module=Hello/1.0 path=${prefix}/modules/Hello host=login01 time=1.0
user=bob module=Hello/1.0 path=${prefix}/modules/Hello host=login02 time=3.0
EOF

out=$("${tool}" used --prefix "${prefix}" "${work}/moduleUsage.log")
check "module-load aggregates" "${out}" "path=${prefix}/modules/Hello kind=module-load last=3.0 count=2"

touch "${work}/empty.json"
check "nothing under message" "$("${tool}" used --prefix "${prefix}" "${work}/empty.json")" "nothing under ${prefix}"

"${tool}" used --prefix "${prefix}" "${work}/xalt.json" --require-none >/dev/null 2>/dev/null
check "require-none with hits" "$?" "2"
check "require-none without hits" "$("${tool}" used --prefix "${prefix}" "${work}/empty.json" --require-none >/dev/null; echo $?)" "0"

json=$("${tool}" used --prefix "${prefix}" --json "${work}/xalt.json")
check "json schema" "$(python3 -c "import json,sys; o=json.load(sys.stdin); assert o['schema_version']==1 and o['prefix']=='${prefix}' and len(o['uses'])>=5" <<< "${json}" && echo ok)" "ok"

printf '{"userT":{"exec_path":"/%s/bin/x"}' "${prefix#/}" > "${work}/bad.json"
"${tool}" used --prefix "${prefix}" "${work}/bad.json" >/dev/null 2>"${work}/err"
check "truncated json exit" "$?" "2"
check "truncated json stderr" "$(cat "${work}/err")" "eb-keep-logs: used: ${work}/bad.json is not XALT run JSON"

"${tool}" used "${work}/xalt.json" >/dev/null 2>"${work}/err2"
check "prefix required exit" "$?" "2"
check "prefix required message" "$(cat "${work}/err2")" "eb-keep-logs: used needs --prefix"

page=$(cat "${repo_root}/docs/orgmode/howto/check-prefix-use.org")
check "how-to names the command" "$(grep -q 'used --prefix' <<< "${page}" && echo yes)" "yes"

echo "${fails} failed"
[ "${fails}" -eq 0 ]