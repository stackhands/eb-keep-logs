#!/bin/bash
# Reversible module lifecycle planning and .modulerc.lua generation.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_lifecycle.sh
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

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-lifecycle.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

software="${work}/software"
modules="${work}/modules"
ec_dir="${work}/easyconfigs"
mkdir -p "${ec_dir}"
for mod in \
    "GCCcore/15.2.0" \
    "ActiveApp/2.0" \
    "WarnApp/1.0" \
    "ForbidApp/1.0" \
    "DeadApp/1.0" \
    "LibDep/1.0" \
    "MissingApp/1.0"
do
    mkdir -p "${software}/${mod}"
    pkg="${mod%%/*}"
    mkdir -p "${modules}/${pkg}"
    touch "${modules}/${mod}.lua"
done

# Now = 2026-11-17T00:00:00Z = 1794873600
now=1794873600
day=86400
since=$((now - 400 * day))
t_active=$((now - 10 * day))
t_warn=$((now - 100 * day))
t_forbid=$((now - 200 * day))
t_dead=$((now - 380 * day))

cat > "${work}/usage.log" <<EOF
{"userT":{"user":"u1","exec_path":"${software}/ActiveApp/2.0/bin/app","start_time":"${t_active}"}}
user=u2 module=WarnApp/1.0 path=${modules}/WarnApp/1.0.lua host=n1 time=${t_warn}
{"userT":{"user":"u3","exec_path":"${software}/ForbidApp/1.0/bin/old","start_time":"${t_forbid}"}}
{"userT":{"user":"u4","exec_path":"${software}/DeadApp/1.0/bin/dead","start_time":"${t_dead}"}}
EOF

"${tool}" usage --software "${software}" --modules "${modules}" --since "${since}" --json "${work}/usage.log" > "${work}/usage.json"
"${tool}" usage --software "${software}" --modules "${modules}" --json "${work}/usage.log" > "${work}/usage-nosince.json"
"${tool}" usage --software "${software}" --modules "${modules}" --since "$((now - 30 * day))" --json "${work}/usage.log" > "${work}/usage-short.json"
"${tool}" usage --software "${software}" --modules "${modules}" --since "${since}" --unused --json "${work}/usage.log" > "${work}/usage-unused.json"

cat > "${work}/policy.toml" <<'EOF'
[policy]
min_observation_days = 90
warn_after_days = 60
forbid_after_days = 180
remove_after_days = 365
forbid_grace_days = 30
min_hits = 1
keep = ["GCCcore/*"]
EOF

cat > "${work}/easystack.yml" <<'EOF'
easyconfigs:
  - ActiveApp-2.0.eb
EOF

# Mock eb-stack that records its argv and returns rebuild-set.json:
# - DeadApp-1.0.eb: 0 dependents -> candidate-remove
# - LibDep-1.0.eb: runtime dependent ActiveApp/2.0 -> blocked (warn)
# - MissingApp-1.0.eb: listed in missing -> blocked (forbid-after)
mkdir -p "${work}/bin"
cat > "${work}/bin/eb-stack" <<'EOF'
#!/bin/bash
set -euo pipefail
cmd=$1; shift
[ "${cmd}" = "rebuild-set" ]
out_dir=""
installed=""
ec_dirs=0
es_files=0
changed_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --changed) changed_args+=("$2"); shift 2 ;;
        --easyconfigs) [ -d "$2" ]; ec_dirs=$((ec_dirs + 1)); shift 2 ;;
        --easystack) [ -f "$2" ]; es_files=$((es_files + 1)); shift 2 ;;
        --installed) installed="$2"; shift 2 ;;
        --out-dir) out_dir="$2"; shift 2 ;;
        *) echo "unexpected arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "${out_dir}" ] && [ -n "${installed}" ] && [ "${ec_dirs}" -ge 1 ]
printf '%s\n' "${changed_args[@]}" > "${out_dir}/../recorded-changed.txt"
cp "${installed}" "${out_dir}/../recorded-installed.txt"
python3 - "${out_dir}/rebuild-set.json" "${changed_args[@]}" <<'PY'
import json, sys, os
out_path = sys.argv[1]
raw_args = sys.argv[2:]
changed = []
for a in raw_args:
    if a.endswith(".eb"):
        changed.append(os.path.basename(a))
    else:
        with open(a) as f:
            for line in f:
                s = line.strip()
                if s:
                    changed.append(os.path.basename(s))
changed = sorted(set(changed))
missing = [c for c in changed if c == "MissingApp-1.0.eb"]
rows = []
for c in changed:
    if c in missing:
        continue
    mod = c[:-3].replace("-", "/", 1)
    rows.append({
        "changed": c,
        "dependent": mod,
        "dependent_easyconfig": c,
        "edge_kind": "changed",
        "class": "must-rebuild",
        "reason": "patched easyconfig",
    })
    if c == "LibDep-1.0.eb":
        rows.append({
            "changed": c,
            "dependent": "ActiveApp/2.0",
            "dependent_easyconfig": "ActiveApp-2.0.eb",
            "edge_kind": "runtime",
            "class": "no-rebuild",
            "reason": "runtime dependency",
        })
doc = {
    "schema_version": 5,
    "generated_at": "2026-11-17T00:00:00Z",
    "installed_source": "",
    "symbols_checked": False,
    "easystacks": [],
    "changed": changed,
    "reach": {},
    "missing": missing,
    "unresolved": [],
    "notes": [],
    "counts": {"no-rebuild": 0, "review": 0, "must-rebuild": 0},
    "rows": rows,
}
with open(out_path, "w") as f:
    json.dump(doc, f)
PY
EOF
chmod +x "${work}/bin/eb-stack"

plan_json=$("${tool}" lifecycle \
    --policy "${work}/policy.toml" \
    --easyconfigs "${ec_dir}" \
    --easystack "${work}/easystack.yml" \
    --eb-stack "${work}/bin/eb-stack" \
    --modulerc-out "${work}/modulerc.lua" \
    --now "${now}" \
    --json "${work}/usage.json")

check "lifecycle json classification and guards" "$(python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["schema_version"] == 1
assert d["kind"] == "lifecycle"
assert d["observed_days"] == 400
assert d["observation_satisfied"] is True
assert d["dependents_checked"] is True
assert d["counts"] == {"keep": 2, "warn": 2, "forbid-after": 2, "candidate-remove": 1}, d["counts"]
by_mod = {e["module"]: e for e in d["entries"]}
assert by_mod["ActiveApp/2.0"]["action"] == "keep"
assert by_mod["GCCcore/15.2.0"]["action"] == "keep"
assert by_mod["WarnApp/1.0"]["action"] == "warn"
assert by_mod["WarnApp/1.0"]["forbid_after"] == "2027-03-07"
assert by_mod["ForbidApp/1.0"]["action"] == "forbid-after"
assert by_mod["ForbidApp/1.0"]["forbid_after"] == "2026-12-17"
assert by_mod["DeadApp/1.0"]["action"] == "candidate-remove"
assert by_mod["DeadApp/1.0"]["dependents"] == []
assert by_mod["LibDep/1.0"]["action"] == "warn"
assert by_mod["LibDep/1.0"]["dependents"] == ["ActiveApp/2.0"]
assert by_mod["LibDep/1.0"]["forbid_after"] is None
assert by_mod["MissingApp/1.0"]["action"] == "forbid-after"
assert "missing from eb-stack graph" in by_mod["MissingApp/1.0"]["blocked_reason"]
print("ok")
' <<<"${plan_json}")" "ok"

check "modulerc.lua written and matches json" "$(cmp -s "${work}/modulerc.lua" <(python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["modulerc_lua"])' <<<"${plan_json}") && echo ok)" "ok"
check "modulerc.lua warns WarnApp" "$(grep -c 'name = "WarnApp/1.0"' "${work}/modulerc.lua")" "1"
check "modulerc.lua forbids ForbidApp" "$(grep -c 'name = "ForbidApp/1.0"' "${work}/modulerc.lua")" "1"
check "modulerc.lua hides and forbids DeadApp" "$(grep -c 'hide_version("DeadApp/1.0")' "${work}/modulerc.lua")" "1"
check "modulerc.lua does not forbid GCCcore" "$(grep -c 'GCCcore' "${work}/modulerc.lua")" "0"
check "modulerc.lua does not emit forbid for LibDep with dependents" "$(grep -c 'name = "LibDep/1.0"' "${work}/modulerc.lua")" "0"

# Never deletes any software or module files
check "software tree intact" "$(find "${software}" -mindepth 2 -maxdepth 2 -type d | wc -l)" "7"
check "module tree intact" "$(find "${modules}" -name '*.lua' | wc -l)" "7"

# Default text output starts with action token
plan_text=$(EB_KEEP_LOGS_NOW="${now}" "${tool}" lifecycle \
    --policy "${work}/policy.toml" \
    --easyconfigs "${ec_dir}" \
    --eb-stack "${work}/bin/eb-stack" \
    "${work}/usage.json")
check "text output lists candidate-remove DeadApp" "$(grep -c '^candidate-remove DeadApp/1.0 ' <<<"${plan_text}")" "1"
check "text output lists dependents on LibDep" "$(grep -c '^warn LibDep/1.0 .* dependents=ActiveApp/2.0 ' <<<"${plan_text}")" "1"

# Observation window guard: missing --since blocks candidate-remove
nosince_json=$("${tool}" lifecycle --policy "${work}/policy.toml" --easyconfigs "${ec_dir}" --eb-stack "${work}/bin/eb-stack" --now "${now}" --json "${work}/usage-nosince.json")
check "usage without --since blocks candidate-remove" "$(python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["observation_satisfied"] is False
assert d["counts"]["candidate-remove"] == 0
print("ok")
' <<<"${nosince_json}")" "ok"

# Observation window guard: short window (< min_observation_days) blocks candidate-remove
short_json=$("${tool}" lifecycle --policy "${work}/policy.toml" --easyconfigs "${ec_dir}" --eb-stack "${work}/bin/eb-stack" --now "${now}" --json "${work}/usage-short.json")
check "short observation window blocks candidate-remove" "$(python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["observed_days"] == 30
assert d["observation_satisfied"] is False
assert d["counts"]["candidate-remove"] == 0
print("ok")
' <<<"${short_json}")" "ok"

# Without --easyconfigs or --rebuild-set, candidate-remove is blocked
nocheck_json=$("${tool}" lifecycle --policy "${work}/policy.toml" --now "${now}" --json "${work}/usage.json")
check "omitting --easyconfigs blocks candidate-remove" "$(python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["dependents_checked"] is False
assert d["counts"]["candidate-remove"] == 0
by_mod = {e["module"]: e for e in d["entries"]}
assert by_mod["DeadApp/1.0"]["action"] == "forbid-after"
assert "dependent modules not checked" in by_mod["DeadApp/1.0"]["blocked_reason"]
print("ok")
' <<<"${nocheck_json}")" "ok"

# Precomputed --rebuild-set JSON works without invoking eb-stack
cat > "${work}/precomputed.json" <<'EOF'
{
  "schema_version": 5,
  "changed": ["DeadApp-1.0.eb", "LibDep-1.0.eb"],
  "missing": [],
  "rows": [
    {"changed": "DeadApp-1.0.eb", "dependent": "DeadApp/1.0", "dependent_easyconfig": "DeadApp-1.0.eb", "edge_kind": "changed", "class": "must-rebuild", "reason": "patched"},
    {"changed": "LibDep-1.0.eb", "dependent": "LibDep/1.0", "dependent_easyconfig": "LibDep-1.0.eb", "edge_kind": "changed", "class": "must-rebuild", "reason": "patched"},
    {"changed": "LibDep-1.0.eb", "dependent": "ActiveApp/2.0", "dependent_easyconfig": "ActiveApp-2.0.eb", "edge_kind": "builddependency", "class": "review", "reason": "builddep"}
  ]
}
EOF
pre_json=$("${tool}" lifecycle --policy "${work}/policy.toml" --rebuild-set "${work}/precomputed.json" --now "${now}" --json "${work}/usage.json")
check "precomputed --rebuild-set checks dependents and blocks unlisted" "$(python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["dependents_checked"] is True
by_mod = {e["module"]: e for e in d["entries"]}
assert by_mod["DeadApp/1.0"]["action"] == "candidate-remove"
assert by_mod["LibDep/1.0"]["action"] == "warn"
assert by_mod["MissingApp/1.0"]["action"] == "forbid-after"
assert "absent from rebuild-set.json" in by_mod["MissingApp/1.0"]["blocked_reason"]
print("ok")
' <<<"${pre_json}")" "ok"

# Batch > 32 candidates uses changed.txt path with eb-stack
many_soft="${work}/many_soft"
many_mod="${work}/many_mod"
mkdir -p "${many_soft}" "${many_mod}"
for idx in $(seq -w 1 40); do
    mkdir -p "${many_soft}/Pkg${idx}/1.0" "${many_mod}/Pkg${idx}"
    touch "${many_mod}/Pkg${idx}/1.0.lua"
done
: > "${work}/empty.log"
"${tool}" usage --software "${many_soft}" --modules "${many_mod}" --since "${since}" --json "${work}/empty.log" > "${work}/many-usage.json"
many_json=$(PATH="${work}/bin:${PATH}" "${tool}" lifecycle --policy "${work}/policy.toml" --easyconfigs "${ec_dir}" --now "${now}" --json "${work}/many-usage.json")
check "more than 32 candidates batch through changed.txt" "$(python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["counts"]["candidate-remove"] == 40
print("ok")
' <<<"${many_json}")" "ok"

# Refusal cases
"${tool}" lifecycle --policy "${work}/policy.toml" --now "${now}" "${work}/usage-unused.json" >/dev/null 2>"${work}/err"
check "partial usage selection refused" "$?" "2"

ln -s "${work}/nowhere.lua" "${work}/sym-modulerc.lua"
"${tool}" lifecycle --policy "${work}/policy.toml" --modulerc-out "${work}/sym-modulerc.lua" --now "${now}" "${work}/usage.json" >/dev/null 2>"${work}/err"
check "symlink --modulerc-out refused" "$?" "2"

cat > "${work}/bad-policy.toml" <<'EOF'
min_observation_days = 90
warn_after_days = 200
forbid_after_days = 100
remove_after_days = 365
EOF
"${tool}" lifecycle --policy "${work}/bad-policy.toml" --modulerc-out "${work}/should-not-exist.lua" --now "${now}" "${work}/usage.json" >/dev/null 2>"${work}/err"
check "invalid policy order refused" "$?" "2"
check "no modulerc written on error" "$(test -e "${work}/should-not-exist.lua" && echo bad || echo ok)" "ok"

PATH="/bin:/usr/bin" "${tool}" lifecycle --policy "${work}/policy.toml" --easyconfigs "${ec_dir}" --now "${now}" "${work}/usage.json" >/dev/null 2>"${work}/err"
check "missing eb-stack on PATH refused" "$?" "2"

echo "${fails} failed"
[ "${fails}" -eq 0 ]
