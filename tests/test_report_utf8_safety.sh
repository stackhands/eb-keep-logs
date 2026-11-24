#!/bin/bash
# loads, used, pending, and usage read module names and paths from Lmod
# and XALT records and from EasyBuild dry-run reports, none of which the
# tool controls. A byte in one of those that is not valid UTF-8 must not
# reach stdout raw, and --json must keep printing a string for it, not
# switch to a list of byte values. The same holds for a value given on
# the command line that the report prints back: loads --module, used
# --prefix, usage --software and --modules, runs --exec, and lifecycle
# --policy.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_report_utf8_safety.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac
cd "${repo_root}" || exit 1

fails=0
# shellcheck source=tests/lib/check.sh
. "${repo_root}/tests/lib/check.sh"

strict_utf8() {
    PYTHONIOENCODING=utf-8:strict python3 -c "
import sys
data = sys.stdin.buffer.read()
data.decode('utf-8', 'strict')
print('ok')
" 2>/dev/null
}

json_string_field() {
    # $1: the json text on stdin; $2 $3: a dotted path to a list index then a field, e.g. loads 0 path
    python3 -c "
import json, sys
doc = json.load(sys.stdin)
node = doc['$1'][$2]
value = node['$3']
print('str' if isinstance(value, str) else type(value).__name__)
"
}

json_top_field() {
    # $1: a top-level field of the json text on stdin; prints its value
    # when it is a string, and its type otherwise.
    PYTHONIOENCODING=utf-8:strict python3 -c "
import json, sys
value = json.load(sys.stdin)['$1']
print(value if isinstance(value, str) else type(value).__name__)
"
}

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-utf8.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

# --- loads: a bad byte in an Lmod path -----------------------------------
printf 'user=alice module=GROMACS/2024.1 path=/cvmfs/\xffgromacs.lua host=login01 time=1\n' \
    > "${work}/moduleUsage.log"

text=$("${tool}" loads --module GROMACS/2024.1 "${work}/moduleUsage.log")
printf '%s\n' "${text}" > "${work}/loads.text"
check "loads text is strict UTF-8" "$(strict_utf8 < "${work}/loads.text")" "ok"

json=$("${tool}" loads --module GROMACS/2024.1 --json "${work}/moduleUsage.log")
printf '%s\n' "${json}" > "${work}/loads.json"
check "loads json is strict UTF-8" "$(strict_utf8 < "${work}/loads.json")" "ok"
check "loads json path stays a string" "$(json_string_field loads 0 path < "${work}/loads.json")" "str"

# --- used: a bad byte in an Lmod path -------------------------------------
printf 'user=alice module=GROMACS/2024.1 path=/opt/pkg/modules/GROMACS/\xff2024.1 host=login01 time=1\n' \
    > "${work}/used.log"

text=$("${tool}" used --prefix /opt/pkg "${work}/used.log")
printf '%s\n' "${text}" > "${work}/used.text"
check "used text is strict UTF-8" "$(strict_utf8 < "${work}/used.text")" "ok"

json=$("${tool}" used --prefix /opt/pkg --json "${work}/used.log")
printf '%s\n' "${json}" > "${work}/used.json"
check "used json is strict UTF-8" "$(strict_utf8 < "${work}/used.json")" "ok"
check "used json path stays a string" "$(json_string_field uses 0 path < "${work}/used.json")" "str"

# --- pending: a bad byte in a dry-run module name -------------------------
printf ' * [ ] $CFGS/f/flex/flex-2.6.4.eb (module: fl\xffex/2.6.4)\n' \
    > "${work}/dryrun.log"

text=$("${tool}" pending "${work}/dryrun.log")
printf '%s\n' "${text}" > "${work}/pending.text"
check "pending text is strict UTF-8" "$(strict_utf8 < "${work}/pending.text")" "ok"

json=$("${tool}" pending --json "${work}/dryrun.log")
printf '%s\n' "${json}" > "${work}/pending.json"
check "pending json is strict UTF-8" "$(strict_utf8 < "${work}/pending.json")" "ok"
check "pending json name stays a string" "$(json_string_field entries 0 name < "${work}/pending.json")" "str"

# --- usage: a bad byte in an installed module's directory name -----------
mkdir -p "${work}/software/pkg"$'\xff'"/1.0"
mkdir -p "${work}/modules"

text=$("${tool}" usage --software "${work}/software" --modules "${work}/modules" "${work}/used.log")
printf '%s\n' "${text}" > "${work}/usage.text"
check "usage text is strict UTF-8" "$(strict_utf8 < "${work}/usage.text")" "ok"

json=$("${tool}" usage --software "${work}/software" --modules "${work}/modules" --json "${work}/used.log")
printf '%s\n' "${json}" > "${work}/usage.json"
check "usage json is strict UTF-8" "$(strict_utf8 < "${work}/usage.json")" "ok"
check "usage json module stays a string" "$(json_string_field packages 0 module < "${work}/usage.json")" "str"

# U+FFFD, the replacement character, as its UTF-8 bytes whatever the locale.
fffd=$'\xef\xbf\xbd'

# --- loads --module: a bad byte in the module asked for ------------------
text=$("${tool}" loads --module $'bad\xffmodule' "${work}/moduleUsage.log")
printf '%s\n' "${text}" > "${work}/loads-arg.text"
check "loads text of a bad --module is strict UTF-8" "$(strict_utf8 < "${work}/loads-arg.text")" "ok"
check "loads text of a bad --module replaces the byte" "${text}" "no load of bad${fffd}module"

json=$("${tool}" loads --module $'bad\xffmodule' --json "${work}/moduleUsage.log")
printf '%s\n' "${json}" > "${work}/loads-arg.json"
check "loads json of a bad --module is strict UTF-8" "$(strict_utf8 < "${work}/loads-arg.json")" "ok"
check "loads json module is the replaced string" "$(json_top_field module < "${work}/loads-arg.json")" "bad${fffd}module"

# --- used --prefix: a bad byte in the prefix asked for --------------------
text=$("${tool}" used --prefix $'/bad\xffprefix' "${work}/used.log")
printf '%s\n' "${text}" > "${work}/used-arg.text"
check "used text of a bad --prefix is strict UTF-8" "$(strict_utf8 < "${work}/used-arg.text")" "ok"
check "used text of a bad --prefix replaces the byte" "${text}" "nothing under /bad${fffd}prefix"

json=$("${tool}" used --prefix $'/bad\xffprefix' --json "${work}/used.log")
printf '%s\n' "${json}" > "${work}/used-arg.json"
check "used json of a bad --prefix is strict UTF-8" "$(strict_utf8 < "${work}/used-arg.json")" "ok"
check "used json prefix is the replaced string" "$(json_top_field prefix < "${work}/used-arg.json")" "/bad${fffd}prefix"

# --- usage --software and --modules: a bad byte in each directory --------
mkdir -p "${work}/soft"$'\xff'"ware/pkg/1.0" "${work}/mod"$'\xff'"ules"
json=$("${tool}" usage --software "${work}/soft"$'\xff'"ware" --modules "${work}/mod"$'\xff'"ules" --json "${work}/used.log")
printf '%s\n' "${json}" > "${work}/usage-arg.json"
check "usage json of bad directories is strict UTF-8" "$(strict_utf8 < "${work}/usage-arg.json")" "ok"
check "usage json software is the replaced string" "$(json_top_field software < "${work}/usage-arg.json")" "${work}/soft${fffd}ware"
check "usage json modules is the replaced string" "$(json_top_field modules < "${work}/usage-arg.json")" "${work}/mod${fffd}ules"

# --- a bad byte is matched as given and replaced only where printed -------
printf 'user=alice module=pkg/1.0 path=/opt/p\xffkg/modules/pkg/1.0 host=login01 time=1\n' \
    > "${work}/used-bad-prefix.log"
text=$("${tool}" used --prefix $'/opt/p\xffkg' "${work}/used-bad-prefix.log")
check "used --prefix with a bad byte matches the records under it" "${text}" \
    "path=/opt/p${fffd}kg/modules/pkg/1.0 kind=module-load last=1 count=1"

printf '%s\n' "user=alice module=pkg/1.0 path=${work}/mod"$'\xff'"ules/pkg/1.0.lua host=login01 time=1" \
    > "${work}/usage-bad-modules.log"
text=$("${tool}" usage --software "${work}/soft"$'\xff'"ware" --modules "${work}/mod"$'\xff'"ules" "${work}/usage-bad-modules.log")
check "usage --modules with a bad byte matches the records under it" "${text}" "active pkg/1.0 hits=1 last=1"

mkdir -p "${work}/twins/pkg"$'\xfe'"/1.0" "${work}/twins/pkg"$'\xff'"/1.0"
printf '%s\n' "user=alice module=pkg"$'\xff'"/1.0 path=${work}/modules/pkg.lua host=login01 time=1" \
    > "${work}/usage-twins.log"
text=$("${tool}" usage --software "${work}/twins" --modules "${work}/modules" "${work}/usage-twins.log")
check "usage keeps two names that differ only in a bad byte apart" "${text}" \
    "unused pkg${fffd}/1.0"$'\n'"active pkg${fffd}/1.0 hits=1 last=1"

# --- runs --exec: a bad byte in the executable asked for -----------------
printf '%s\n' '{"userT":{"user":"ada","exec_path":"/opt/site/bin/gmx","syshost":"login01","start_time":"1"}}' \
    > "${work}/runs.json"

text=$("${tool}" runs --exec $'/bad\xffexec' "${work}/runs.json")
printf '%s\n' "${text}" > "${work}/runs-arg.text"
check "runs text of a bad --exec is strict UTF-8" "$(strict_utf8 < "${work}/runs-arg.text")" "ok"
check "runs text of a bad --exec replaces the byte" "${text}" "no run of /bad${fffd}exec"

json=$("${tool}" runs --exec $'/bad\xffexec' --json "${work}/runs.json")
printf '%s\n' "${json}" > "${work}/runs-arg.json"
check "runs json of a bad --exec is strict UTF-8" "$(strict_utf8 < "${work}/runs-arg.json")" "ok"
check "runs json exec is the replaced string" "$(json_top_field exec < "${work}/runs-arg.json")" "/bad${fffd}exec"

# --- lifecycle --policy: a bad byte in the policy file's name ------------
printf '%s\n' 'min_observation_days = 90' 'warn_after_days = 60' 'forbid_after_days = 180' 'remove_after_days = 365' \
    > "${work}/pol"$'\xff'"icy.toml"
"${tool}" usage --software "${work}/software" --modules "${work}/modules" --json "${work}/used.log" \
    > "${work}/lifecycle-usage.json"
json=$("${tool}" lifecycle --policy "${work}/pol"$'\xff'"icy.toml" --now 1794873600 --json "${work}/lifecycle-usage.json")
printf '%s\n' "${json}" > "${work}/lifecycle-arg.json"
check "lifecycle json of a bad --policy is strict UTF-8" "$(strict_utf8 < "${work}/lifecycle-arg.json")" "ok"
check "lifecycle json policy is the replaced string" "$(json_top_field policy < "${work}/lifecycle-arg.json")" "${work}/pol${fffd}icy.toml"

echo "${fails} failed"
[ "${fails}" -eq 0 ]
