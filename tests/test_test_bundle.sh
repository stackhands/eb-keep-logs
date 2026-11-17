#!/bin/bash
# Validate test-bundle and test-compare outputs and schemas.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_test_bundle.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
schema_dir="${repo_root}/docs/orgmode/reference/json"
tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac

if ! python3 -c "import jsonschema" 2>/dev/null; then
    python3 -m pip install -q --user jsonschema
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-bundle.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

cat > "${work}/stdout-a.log" <<'EOF'
line one  
line two
EOF
cat > "${work}/stderr-a.log" <<'EOF'
warn
EOF
cat > "${work}/stdout-b.log" <<'EOF'
line one
line two changed
EOF
cat > "${work}/stderr-b.log" <<'EOF'
warn
EOF
cat > "${work}/in-a.txt" <<'EOF'
alpha
EOF
cat > "${work}/in-b.txt" <<'EOF'
beta
EOF

"${tool}" test-bundle \
    --test-id qe.pw.scf-si \
    --suite-revision 5f6a9cc \
    --eessi-target x86_64/intel/sapphirerapids \
    --stdout "${work}/stdout-a.log" \
    --stderr "${work}/stderr-a.log" \
    --input "${work}/in-a.txt" \
    --input "${work}/in-b.txt" \
    --module QuantumESPRESSO/7.4=/cvmfs/eessi/software/QuantumESPRESSO/7.4.lua \
    --module FFTW/3.3=/cvmfs/eessi/software/FFTW/3.3.lua \
    --seed 42 \
    --allocation "nodes=1 ntasks=32" \
    --binding "rank0->core0, rank1->core1" \
    --cpu "AMD EPYC 7B13 (32)" \
    --gpu "none" \
    --out "${work}/bundle-a.json"

"${tool}" test-bundle \
    --test-id qe.pw.scf-si \
    --suite-revision 5f6a9cc \
    --eessi-target x86_64/intel/sapphirerapids \
    --stdout "${work}/stdout-b.log" \
    --stderr "${work}/stderr-b.log" \
    --input "${work}/in-a.txt" \
    --input "${work}/in-b.txt" \
    --module QuantumESPRESSO/7.4=/cvmfs/eessi/software/QuantumESPRESSO/7.4.lua \
    --module FFTW/3.3=/cvmfs/eessi/software/FFTW/3.3.lua \
    --seed 42 \
    --allocation "nodes=2 ntasks=64" \
    --binding "rank0->core0, rank1->core2" \
    --cpu "AMD EPYC 7B13 (64)" \
    --gpu "none" \
    --out "${work}/bundle-b.json"

python3 "${repo_root}/tests/json_schema_validate.py" "${schema_dir}/test-bundle.schema.json" < "${work}/bundle-a.json"
python3 "${repo_root}/tests/json_schema_validate.py" "${schema_dir}/test-bundle.schema.json" < "${work}/bundle-b.json"

"${tool}" test-compare --json "${work}/bundle-a.json" "${work}/bundle-b.json" > "${work}/compare.json"
python3 "${repo_root}/tests/json_schema_validate.py" "${schema_dir}/test-compare.schema.json" < "${work}/compare.json"

python3 - "${work}/compare.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
fields = {f["field"] for f in doc["differing_fields"]}
assert "stdout_sha256" in fields, fields
assert "scheduler.allocation" in fields, fields
assert "hardware.cpu" in fields, fields
PY

echo "ok test-bundle/test-compare"
