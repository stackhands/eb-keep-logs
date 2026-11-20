#!/usr/bin/env bash
# Signal and crash safety of `rotate`.
#
# TOOL_BIN must name the eb-keep-logs-test-ops artifact, a build with
# atomic.replaceable true, so EB_KEEP_LOGS_TEST_KILL_AT (one of after-lock,
# mid-copy, after-rename or before-metrics-write) makes rotate send itself
# EB_KEEP_LOGS_TEST_KILL_SIG (KILL, TERM or INT; KILL when unset) at that
# point, standing in for a crash or a terminated process in a reproducible
# way. An ordinary build reads neither variable and cannot be made to do
# this; this suite never runs against one.
#   TOOL_BIN=zig-out/bin/eb-keep-logs-test-ops bash tests/test_crash_safety.sh
set -u
tool="${TOOL_BIN:?TOOL_BIN must name the eb-keep-logs-test-ops artifact}"
work=$(mktemp -d "${TMPDIR:-/tmp}/ekl-crash.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
fail=0
note() {
    echo "FAIL: $1" >&2
    fail=1
}

# The exit code a process with no signal handler leaves after SIG kills it.
sig_exit() {
    case "$1" in
        TERM) echo 143 ;;
        INT) echo 130 ;;
        KILL) echo 137 ;;
    esac
}

# after-lock, mid-copy and before-metrics-write: none of the three should
# ever lose rotate's lock, tear its metrics file, or stop a later rotate
# from finishing.
for step in after-lock mid-copy before-metrics-write; do
    for sig in TERM INT KILL; do
        root="${work}/${step}-${sig}"
        mkdir -p "${root}"
        # Seeds a metrics file with real prior content, from a run with
        # nothing to compress, before the fixture file to kill over exists.
        "${tool}" rotate "${root}" --compress-after 999 --metrics-file "${root}/m.prom" > /dev/null 2>&1
        before_metrics=$(cat "${root}/m.prom" 2> /dev/null || true)
        mkdir -p "${root}/20200101_000000"
        printf 'line one\n' > "${root}/20200101_000000/a.log"

        EB_KEEP_LOGS_TEST_KILL_AT="${step}" EB_KEEP_LOGS_TEST_KILL_SIG="${sig}" \
            "${tool}" rotate "${root}" --compress-after 999 --metrics-file "${root}/m.prom" > /dev/null 2>&1
        ec=$?
        want=$(sig_exit "${sig}")
        [ "${ec}" = "${want}" ] || note "${step}/${sig}: exit ${ec} after the kill, want ${want}"

        flock -n "${root}/.eb-keep-logs-rotate.lock" true 2> /dev/null \
            || note "${step}/${sig}: rotate's lock is still held after the kill"

        after_metrics=$(cat "${root}/m.prom" 2> /dev/null || true)
        [ "${before_metrics}" = "${after_metrics}" ] \
            || note "${step}/${sig}: the metrics file changed from a kill before it was due to be written"

        timeout 5 "${tool}" rotate "${root}" --compress-after 999 --metrics-file "${root}/m.prom" > /dev/null 2>&1
        [ $? -eq 0 ] || note "${step}/${sig}: a rotate after the kill did not finish cleanly"
    done
done

# after-rename: a run with two files and a .licensed-logs line for each. A
# kill right after the first file is compressed and its own line updated
# must leave the second file's line alone, pointing at the file as it still
# stands; a later rotate must then bring every line up to date, with
# neither file left uncompressed or unlisted.
root="${work}/after-rename"
mkdir -p "${root}/20200101_120000"
printf 'one\n' > "${root}/20200101_120000/a.log"
printf 'two\n' > "${root}/20200101_120000/b.log"
printf '%s/20200101_120000/a.log\n%s/20200101_120000/b.log\n' "${root}" "${root}" \
    > "${root}/20200101_120000/.licensed-logs"

EB_KEEP_LOGS_TEST_KILL_AT=after-rename "${tool}" rotate "${root}" --compress-after 999 > /dev/null 2>&1
ec=$?
[ "${ec}" = 137 ] || note "after-rename: exit ${ec} from the default signal, want 137"

done_count=0
[ -e "${root}/20200101_120000/a.log.gz" ] && done_count=$((done_count + 1))
[ -e "${root}/20200101_120000/b.log.gz" ] && done_count=$((done_count + 1))
[ "${done_count}" = 1 ] || note "after-rename: expected exactly one file compressed by the kill, saw ${done_count}"
grep -qxF "${root}/20200101_120000/a.log.gz" "${root}/20200101_120000/.licensed-logs" \
    || grep -qxF "${root}/20200101_120000/a.log" "${root}/20200101_120000/.licensed-logs" \
    || note "after-rename: a.log's line in .licensed-logs is neither name right after the kill"
grep -qxF "${root}/20200101_120000/b.log.gz" "${root}/20200101_120000/.licensed-logs" \
    || grep -qxF "${root}/20200101_120000/b.log" "${root}/20200101_120000/.licensed-logs" \
    || note "after-rename: b.log's line in .licensed-logs is neither name right after the kill"

"${tool}" rotate "${root}" --compress-after 999 > /dev/null 2>&1
[ -e "${root}/20200101_120000/a.log" ] && note "after-rename: a.log was still there to compress after the second rotate"
[ -e "${root}/20200101_120000/b.log" ] && note "after-rename: b.log was still there to compress after the second rotate"
[ -e "${root}/20200101_120000/a.log.gz" ] || note "after-rename: a.log.gz is missing after the second rotate"
[ -e "${root}/20200101_120000/b.log.gz" ] || note "after-rename: b.log.gz is missing after the second rotate"
stale=$(grep -vF '.gz' "${root}/20200101_120000/.licensed-logs" || true)
[ -z "${stale}" ] \
    || note "after-rename: .licensed-logs still names a file by its pre-compression path: ${stale}"

[ "${fail}" = 0 ]
