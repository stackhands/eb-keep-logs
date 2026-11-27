#!/bin/bash
# lifecycle reads a module name, and the names of its installed
# dependents, from a usage report built from directory entries the tool
# does not control. A Linux file name may hold a raw newline, which
# formatModulerc must not put, unescaped, into a `--` comment line of the
# generated .modulerc.lua: an unescaped newline there ends the comment
# early and turns the rest of the name into unquoted, uncommented Lua.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_lifecycle_modulerc_safety.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac
cd "${repo_root}" || exit 1

fails=0
# shellcheck source=tests/lib/check.sh
. "${repo_root}/tests/lib/check.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-modulerc-safety.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

software="${work}/software"
modules="${work}/modules"
mkdir -p "${modules}"

# A directory name holding a raw newline and a Lua-breaking quote, as a
# POSIX file name may: anything but '/' and NUL.
evil=$'Evil\napp = "pwned"\n--'
mkdir -p "${software}/${evil}/1.0/bin"
: > "${software}/${evil}/1.0/bin/app"
chmod +x "${software}/${evil}/1.0/bin/app"

now=1794873600
day=86400
since=$((now - 400 * day))
t_warn=$((now - 100 * day))

python3 - "${work}/usage.log" "${software}/${evil}/1.0/bin/app" "${t_warn}" <<'PY'
import json
import sys

path, exec_path, t_warn = sys.argv[1], sys.argv[2], sys.argv[3]
rec = {"userT": {"user": "u1", "exec_path": exec_path, "start_time": t_warn}}
with open(path, "w") as f:
    f.write(json.dumps(rec) + "\n")
PY

"${tool}" usage --software "${software}" --modules "${modules}" --since "${since}" \
    --json "${work}/usage.log" > "${work}/usage.json"

cat > "${work}/policy.toml" <<'EOF'
[policy]
min_observation_days = 90
warn_after_days = 60
forbid_after_days = 180
remove_after_days = 365
forbid_grace_days = 30
min_hits = 1
EOF

"${tool}" lifecycle --policy "${work}/policy.toml" \
    --modulerc-out "${work}/out.modulerc.lua" --now "${now}" \
    "${work}/usage.json" > "${work}/lifecycle.out" 2> "${work}/lifecycle.err"
check "lifecycle with a hostile module name exits 0" "$?" "0"
check "lifecycle prints nothing to stderr" "$(cat "${work}/lifecycle.err")" ""

# With every field escaped to a single line, the generated file has the
# same, fixed line count for one warn-with-forbid_after entry, whatever
# bytes the module name and its dependents hold.
check "modulerc has the fixed line count for one warn entry" \
    "$(wc -l < "${work}/out.modulerc.lua")" "10"

# The smoking gun: the raw module name's embedded `app = "pwned"` must
# never appear as its own, uncommented, unquoted line.
if grep -qxF 'app = "pwned"' "${work}/out.modulerc.lua"; then
    echo "FAIL modulerc has no bare injected statement line" >&2
    fails=$((fails + 1))
else
    echo "ok   modulerc has no bare injected statement line"
fi

# Every non-blank line is either a `--` comment or part of a recognized
# Lua statement; nothing from a hostile name stands on its own.
bad_lines=$(grep -vE '^$|^--|^forbid\{$|^hide_version\(|^  (name|after|nearly_message|message) = |^\}$' \
    "${work}/out.modulerc.lua" || true)
check "no line falls outside a comment or a known statement shape" "${bad_lines}" ""

echo "${fails} failed"
[ "${fails}" -eq 0 ]
