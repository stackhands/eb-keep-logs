#!/bin/bash
# What an EasyBuild dry-run or missing-modules report still has to build.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_pending.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac

fails=0
# shellcheck source=tests/lib/check.sh
. "${repo_root}/tests/lib/check.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-pending.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
cat > "${work}/dry.txt" << 'EOF'
== Temporary log file in case of crash /tmp/eb-3lh496ml/easybuild-hxmie76g.log
Dry run: printing build status of easyconfigs and dependencies
CFGS=/Volumes/work/easybuild-easyconfigs/easybuild/easyconfigs
 * [x] $CFGS/z/zlib/zlib-1.2.12.eb (module: zlib/1.2.12)
 * [x] $CFGS/m/M4/M4-1.4.19.eb (module: M4/1.4.19)
 * [ ] $CFGS/f/flex/flex-2.6.4.eb (module: flex/2.6.4)
 * [F] $CFGS/b/binutils/binutils-2.39.eb (module: binutils/2.39)
 * [R] $CFGS/g/GCC/GCC-13.2.0.eb (module: GCC/13.2.0)
EOF
cat > "${work}/present.txt" << 'EOF'
 * [x] $CFGS/z/zlib/zlib-1.2.12.eb (module: zlib/1.2.12)
EOF
cat > "${work}/missing.txt" << 'EOF'
== temporary log file in case of crash /tmp/eb-bjCz9b/easybuild-CSAvhK.log

2 out of 54 required modules missing:

* Bazel/0.20.0-GCCcore-8.2.0 (Bazel-0.20.0-GCCcore-8.2.0.eb)
* TensorFlow/1.13.1-foss-2019a-Python-3.7.2 (TensorFlow-1.13.1-foss-2019a-Python-3.7.2.eb)
EOF
cat > "${work}/terse.txt" << 'EOF'
x /git/easyconfigs/m/M4/M4-1.4.19.eb
- /git/easyconfigs/f/flex/flex-2.6.4.eb
EOF

check "dry-run still to build" "$("${tool}" pending "${work}/dry.txt")" "build flex/2.6.4
build binutils/2.39
build GCC/13.2.0"
check "already installed" "$("${tool}" pending "${work}/present.txt")" "nothing to build"
check "missing modules" "$("${tool}" pending "${work}/missing.txt")" "missing Bazel/0.20.0-GCCcore-8.2.0
missing TensorFlow/1.13.1-foss-2019a-Python-3.7.2"
check "terse dry-run" "$("${tool}" pending "${work}/terse.txt")" "build /git/easyconfigs/f/flex/flex-2.6.4.eb"
echo 'not a report' > "${work}/nope.txt"
"${tool}" pending "${work}/nope.txt" >/dev/null 2>"${work}/err"
check "not a report" "$?" "2"
check "the refusal names the report" "$(cat "${work}/err")" "eb-keep-logs: pending: ${work}/nope.txt is not a dry-run or missing-modules report"
page=$(cat "${repo_root}/docs/orgmode/howto/what-a-dry-run-would-build.org")
check "how-to names the command" "$(grep -c 'eb-keep-logs pending' <<< "${page}")" "1"

echo "${fails} failed"
[ "${fails}" -eq 0 ]
