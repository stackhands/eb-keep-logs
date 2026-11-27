#!/bin/bash
# A failed directory fsync after a log is renamed to its .gz and the
# original is unlinked must still count as compressed, since the file
# is already in its new form on disk. So must a failed sync of the run
# directory after its .licensed-logs is rewritten to name the archive,
# and both warnings must name the errno. Needs strace --inject, so this
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

# The same run with a .licensed-logs: after the archive's own directory
# sync, rotate rewrites the list to name the archive and syncs the run
# directory again. That last sync of the run directory is the one to fail.
licensed_run() {
    # $1: a fresh root; the rest: strace options before the command
    local root=$1
    shift
    mkdir -p "${root}/20200101_120000"
    echo "a line of build output" > "${root}/20200101_120000/build.log"
    printf '%s/20200101_120000/build.log\n' "${root}" > "${root}/20200101_120000/.licensed-logs"
    strace -f -y -e trace=fsync "$@" -- \
        env EB_KEEP_LOGS_NOW=1583064000 "${tool}" rotate "${root}" --compress-after 30 2>&1
}

# strace -y names a descriptor by its resolved path.
real_work=$(cd "${work}" && pwd -P)
licensed_run "${work}/plain" -o "${work}/plain-trace" > /dev/null
list_sync=$(grep -n 'fsync(' "${work}/plain-trace" | grep -n "<${real_work}/plain/20200101_120000>)" | tail -n 1 | cut -d: -f1)
check "an uninjected run syncs the run directory after the list" \
    "$([ "${list_sync:-0}" -ge 3 ] && echo yes || echo "no, at ${list_sync:-none}")" "yes"

root="${work}/licensed"
out=$(licensed_run "${root}" -e inject=fsync:error=EIO:when="${list_sync:-0}..${list_sync:-0}" -o "${work}/licensed-trace")
rc=$?
list="${root}/20200101_120000/.licensed-logs"

check "list: exit code" "${rc}" "0"
check "list: the archive exists" "$([ -e "${root}/20200101_120000/build.log.gz" ] && echo present || echo absent)" "present"
check "list: the summary counts the file compressed" "$(printf '%s\n' "${out}" | grep -c '1 file compressed, 0 runs deleted')" "1"
check "list: the list names the archive" "$(cat "${list}")" "${root}/20200101_120000/build.log.gz"
check "list: the failed sync is the run directory's" \
    "$(grep 'fsync(' "${work}/licensed-trace" | grep -c "<${real_work}/licensed/20200101_120000>) = -1 EIO")" "1"
check "list: the sync warning names the list and EIO" "$(printf '%s\n' "${out}" | grep -c 'cannot sync a \.licensed-logs: EIO')" "1"
check "list: the sync warning does not say Unexpected" "$(printf '%s\n' "${out}" | grep -c 'Unexpected')" "0"
check "list: no archive sync warning" "$(printf '%s\n' "${out}" | grep -c 'cannot sync .*build\.log\.gz')" "0"

if [ "${fails}" -ne 0 ]; then echo "${fails} failed"; exit 1; fi
echo "all passed"
