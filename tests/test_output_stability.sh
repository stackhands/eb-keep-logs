#!/bin/bash
# The failed command keeps the same log the shell implementation keeps.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_output_stability.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac
golden="${repo_root}/tests/golden/stability"

fails=0
# shellcheck source=tests/lib/check.sh
. "${repo_root}/tests/lib/check.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-stability.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

# The kept log is the one tests/golden/stability holds.
mkdir -p "${work}/bin" "${work}/logs-n"
printf '== processing EasyBuild easyconfig /ec/Foo-1.0.eb\nerror: bad\n' > "${work}/eb.log"
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
echo "${work}/eb.log"
EOF
chmod +x "${work}/bin/eb"

PATH="${work}/bin:${PATH}" "${tool}" failed 1 Foo-1.0 "${work}/logs-n" > "${work}/failed-n.out" 2> "${work}/failed-n.err"
check "failed kept log byte-identical" "$(cmp -s "${golden}/failed.kept" "${work}/logs-n/Foo-1.0.failed.ebout.log" && echo ok)" "ok"

echo "${fails} failed"
[ "${fails}" -eq 0 ]
