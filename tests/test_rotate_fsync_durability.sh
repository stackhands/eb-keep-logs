#!/bin/bash
# A failed directory fsync after a log is renamed to its .gz and the
# original is unlinked must still count as compressed, since the file
# is already in its new form on disk. Needs strace --inject, so this
# only exercises the zig binary: the shell reference never fsyncs a
# run directory after compressing. strace is required, not optional:
# an environment missing it fails loudly rather than skipping, so a
# runner that drops the dependency cannot quietly stop covering this.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_rotate_fsync_durability.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac
cd "${repo_root}" || exit 1

if ! command -v strace > /dev/null 2>&1; then
    echo "FAIL strace is required to inject the directory fsync failure, and is not installed" >&2
    exit 1
fi

fails=0
# shellcheck source=tests/lib/check.sh
. "${repo_root}/tests/lib/check.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-fsync.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

mkdir -p "${work}/root/20200101_120000"
echo "a line of build output" > "${work}/root/20200101_120000/build.log"

trace="${work}/trace"
out=$(strace -f -y -e trace=fsync -e inject=fsync:error=EIO:when=2..2 -o "${trace}" -- \
    env EB_KEEP_LOGS_NOW=1583064000 "${tool}" rotate "${work}/root" --compress-after 30 2>&1)
rc=$?

check "exit code" "${rc}" "0"
check "the original is gone" "$([ -e "${work}/root/20200101_120000/build.log" ] && echo present || echo gone)" "gone"
check "the archive exists" "$([ -e "${work}/root/20200101_120000/build.log.gz" ] && echo present || echo absent)" "present"
check "the archive is a valid gzip member" "$(gzip -t "${work}/root/20200101_120000/build.log.gz" 2>&1; echo "rc=$?")" "rc=0"
check "the summary counts the file compressed" "$(printf '%s\n' "${out}" | grep -c '1 file compressed, 0 runs deleted')" "1"
check "a sync warning names the archive, not the source" "$(printf '%s\n' "${out}" | grep -c 'cannot sync .*build\.log\.gz')" "1"
check "the sync warning names EIO" "$(printf '%s\n' "${out}" | grep -c 'cannot sync .*build\.log\.gz: EIO')" "1"
check "the sync warning does not say Unexpected" "$(printf '%s\n' "${out}" | grep -c 'Unexpected')" "0"
check "no stray compress refusal" "$(printf '%s\n' "${out}" | grep -c 'cannot compress')" "0"

if [ "${fails}" -ne 0 ]; then echo "${fails} failed"; exit 1; fi
echo "all passed"
