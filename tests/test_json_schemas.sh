#!/bin/bash
# Validate --json output against docs/orgmode/reference/json/*.schema.json.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_json_schemas.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
schema_dir="${repo_root}/docs/orgmode/reference/json"
tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac

if ! python3 -c "import jsonschema" 2>/dev/null; then
    python3 -m pip install -q --user jsonschema
fi

validate() {
    local name=$1
    local cmd=$2
    shift 2
    "${tool}" "${cmd}" "$@" | python3 "${repo_root}/tests/json_schema_validate.py" "${schema_dir}/${name}.schema.json"
}

logs="${repo_root}/tests/fixtures/build-logs"
work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-json.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

cat > "${work}/moduleUsage.log" <<'EOF'
user=alice module=GROMACS/2024.1 path=/cvmfs/g.lua host=login01 time=1731840001.250000
user=cara module=GROMACS/2024.1 path=/other.lua host=login01 time=1731840099.5
EOF

cat > "${work}/runs.json" <<'EOF'
{"userT":{"user":"ada","exec_path":"/opt/site/bin/gmx","syshost":"login01","start_time":"1428767000.5"}}
EOF

cat > "${work}/dry.txt" <<'EOF'
 * [ ] $CFGS/f/flex/flex-2.6.4.eb (module: flex/2.6.4)
 * [R] $CFGS/g/GCC/GCC-13.2.0.eb (module: GCC/13.2.0)
EOF

software="${work}/software"
modules="${work}/modules"
mkdir -p "${software}/Foo/1.0" "${modules}/Foo"
cat > "${work}/xalt.json" <<EOF
{"userT":{"user":"u","exec_path":"${software}/Foo/1.0/bin/foo","start_time":"200"}}
EOF
echo 'user=bob module=Foo/1.0 path='"${modules}/Foo/1.0.lua"' host=login01 time=300' > "${work}/lmod.log"
"${tool}" usage --software "${software}" --modules "${modules}" --since 100 --json "${work}/xalt.json" "${work}/lmod.log" > "${work}/usage.json"
cat > "${work}/policy.toml" <<'EOF'
min_observation_days = 90
warn_after_days = 60
forbid_after_days = 180
remove_after_days = 365
EOF

fails=0
# One table of command and schema. A miss names the command.
schema_miss=
schema_row() {
    local title=$1
    shift
    "$@" || schema_miss="${schema_miss}${title}"$'\n'
}

schema_row "why" validate why why --json "${logs}/20261117_041222"
schema_row "history" validate history history --json --root "${logs}" hello-2.12.1-GCCcore-13.3.0
schema_row "failures" validate failures failures --json --root "${logs}" --package hello --since 2026-11-17
schema_row "loads" validate loads loads --module GROMACS/2024.1 --json "${work}/moduleUsage.log"
schema_row "runs" validate runs runs --exec gmx --json "${work}/runs.json"
schema_row "pending dry-run" validate pending pending --json "${work}/dry.txt"
schema_row "used" validate used used --prefix "${software}/Foo/1.0" --json "${work}/xalt.json"
schema_row "usage" validate usage usage --software "${software}" --modules "${modules}" --json "${work}/xalt.json" "${work}/lmod.log"
schema_row "lifecycle" validate lifecycle lifecycle --policy "${work}/policy.toml" --now 1794873600 --json "${work}/usage.json"
if [ -n "${schema_miss}" ]; then
    echo "FAIL json schemas" >&2
    printf '%s' "${schema_miss}" >&2
    fails=$((fails + 1))
else
    echo "ok   json schemas"
fi

echo "${fails} failed"
[ "${fails}" -eq 0 ]
