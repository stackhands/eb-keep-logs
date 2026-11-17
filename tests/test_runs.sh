#!/bin/bash
# Who ran an executable, from an XALT run record.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_runs.sh
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

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-runs.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
cat > "${work}/runs.json" << 'EOF'
{
  "userT": {
    "cwd": "/lustre/medusa/faheymr",
    "exec_path": "/lustre/medusa/faheymr/hello_world",
    "start_time": 1428766963,
    "syshost": "darter",
    "user": "faheymr"
  }
}
{
  "function": ["MPI_Init"],
  "resultT": { "exec_path": "/lustre/medusa/faheymr/hello_world", "build_user": "faheymr" }
}
{
  "userT": {
    "exec_path": "/opt/site/bin/gmx",
    "start_time": "1428767000.5",
    "syshost": "login01",
    "user": "ada"
  }
}
EOF

out=$("${tool}" runs --exec hello_world "${work}/runs.json")
check "basename match, link record skipped" "${out}" "user=faheymr host=darter time=1428766963 path=/lustre/medusa/faheymr/hello_world"
check "full path" "$("${tool}" runs --exec=/opt/site/bin/gmx "${work}/runs.json")" "user=ada host=login01 time=1428767000.5 path=/opt/site/bin/gmx"
check "none" "$("${tool}" runs --exec missing "${work}/runs.json")" "no run of missing"
"${tool}" runs "${work}/runs.json" >/dev/null 2>"${work}/err"
check "exec is required" "$?" "2"
check "the refusal names the flag" "$(cat "${work}/err")" "eb-keep-logs: runs needs --exec"
page=$(cat "${repo_root}/docs/orgmode/howto/who-ran-an-executable.org")
check "how-to names the command" "$(grep -c 'runs --exec' <<< "${page}")" "1"
check "how-to names the empty answer" "$(grep -c 'no run of' <<< "${page}")" "1"

echo "${fails} failed"
[ "${fails}" -eq 0 ]
