#!/bin/bash
# Run the binary (TOOL_BIN) on fixed invocations and compare exit code,
# stdout and stderr with the expected output under tests/golden/cases, one
# file per case. The work directory shows as @WORK@, this checkout as
# @REPO@. The expected files are the shell implementation's output wherever
# the two implementations agreed, and the binary's where they differed by
# design.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_cases.sh
# RECORD=1 rewrites the expected files from TOOL_BIN instead of comparing.
set -u
repo_root=$(cd "$(dirname "$0")/.." && pwd)
: "${TOOL_BIN:?}"
golden="${repo_root}/tests/golden/cases"
work=$(mktemp -d "${TMPDIR:-/tmp}/ekl-cases.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
real_work=$(realpath "${work}")
mkdir -p "${work}/logs" "${work}/bin" "${golden}"
printf '#!/bin/bash\nexit 0\n' > "${work}/bin/eb"
chmod +x "${work}/bin/eb"
export PATH="${work}/bin:${PATH}"

diffs=0
# The environment each run gets, as env(1) takes it.
run_env=(PATH="${PATH}")
# expect LABEL FILE: compare FILE, with the work directory as @WORK@, against
# the expected file of LABEL, or write it under RECORD=1.
expect() {
    local label=$1 got=$2 want
    want="${golden}/$(printf '%s' "${label}" | tr -c 'A-Za-z0-9_-' '_')"
    sed -e "s|${real_work}|@WORK@|g" -e "s|${work}|@WORK@|g" -e "s|${repo_root}|@REPO@|g" "${got}" > "${work}/got.norm"
    if [ -n "${RECORD:-}" ]; then
        cp "${work}/got.norm" "${want}"
        echo "recorded ${label}"
    elif cmp -s "${want}" "${work}/got.norm"; then
        echo "same ${label}"
    else
        {
            echo "DIFF ${label}"
            diff "${want}" "${work}/got.norm" | sed 's/^/     /'
        } >&2
        diffs=$((diffs + 1))
    fi
}
# compare LABEL ARGS...: run the binary with ARGS and check what it printed.
compare() {
    local label=$1; shift
    env "${run_env[@]}" "${TOOL_BIN}" "$@" > "${work}/n.out" 2> "${work}/n.err"; local nc=$?
    { echo "exit ${nc}"; echo "--- stdout"; cat "${work}/n.out"; echo "--- stderr"; cat "${work}/n.err"; } > "${work}/n.all"
    expect "${label}" "${work}/n.all"
}

compare "no arguments"
compare "--help" --help
compare "-h" -h
compare "unknown command" bogus
compare "failed, too few" failed 1 Foo
compare "failed, bad status" failed x Foo "${work}/logs"
compare "failed, missing logdir" failed 1 Foo "${work}/nope"
compare "failed, success" failed 0 Foo "${work}/logs"
compare "failed, zeros are success" failed 000 Foo "${work}/logs"
compare "failed, no eb log" failed 3 Foo "${work}/logs"
compare "failed, empty tmp logdir" failed 3 Foo "${work}/logs" ""
mkdir -p "${work}/empty"
run_env=(PATH="${work}/empty")
compare "failed, no eb on PATH" failed 3 Foo "${work}/logs"
run_env=(PATH="${PATH}")
printf '#!/bin/bash\nexit 4\n' > "${work}/bin/eb"
compare "failed, eb --last-log fails" failed 3 Foo "${work}/logs"
long="${work}/$(printf 'x%.0s' {1..100})"
mkdir -p "${long}"
echo "link error" > "${long}/easybuild-Foo.log"
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
if [[ " \$* " == *" --output-style=basic "* ]]; then
    echo "${long}/easybuild-Foo.log"
else
    echo "${long}/easybuild-Foo.log" | fold -w 80
fi
EOF
compare "failed, wrapped last-log" failed 3 Foo "${work}/logs"
unset EASYBUILD_TMPDIR
mkdir -p "${work}/ebtmp/eb-1/run-shell-cmd-output/make-1" "${work}/elsewhere"
ln -s ebtmp "${work}/ebtmp-link"
echo "error: undeclared" > "${work}/ebtmp/eb-1/run-shell-cmd-output/make-1/out.txt"
printf '\toutput will be logged to %s/eb-1/run-shell-cmd-output/make-1/out.txt\n' "${work}/ebtmp-link" > "${work}/easybuild-Cmd.log"
printf '#!/bin/bash\necho %s\n' "${work}/easybuild-Cmd.log" > "${work}/bin/eb"
EASYBUILD_TMPDIR="${work}/ebtmp-link" compare "failed, linked EASYBUILD_TMPDIR" failed 3 Cmd "${work}/logs"
compare "failed, EASYBUILD_TMPDIR unset" failed 3 Cmd "${work}/logs"
EASYBUILD_TMPDIR="${work}/elsewhere" compare "failed, output outside EASYBUILD_TMPDIR" failed 3 Cmd "${work}/logs"
printf '== processing EasyBuild easyconfig /ec/Ring-1.0.eb\n' > "${work}/easybuild-ring.log"
printf '#!/bin/bash\necho %s\n' "${work}/easybuild-ring.log" > "${work}/bin/eb"
compare "failed, another build's log" failed 3 Calc-1.0 "${work}/logs"
compare "failed, own log" failed 3 Ring-1.0 "${work}/logs"
ebtmp="$(realpath "${work}")/ebtmp"
mkdir -p "${ebtmp}/eb-1/run-shell-cmd-output/meson-1" "${ebtmp}/eb-1/run-shell-cmd-output/ninja-2" "${work}/obj/meson-logs"
echo meson > "${ebtmp}/eb-1/run-shell-cmd-output/meson-1/out.txt"
echo ninja > "${ebtmp}/eb-1/run-shell-cmd-output/ninja-2/out.txt"
printf '\toutput will be logged to %s/eb-1/run-shell-cmd-output/meson-1/out.txt\n\tmeson test -C %s/obj\n' "${ebtmp}" "${work}" > "${work}/easybuild-Tests.log"
cp "${work}/easybuild-Tests.log" "${work}/easybuild-Sanity.log"
echo '== run.py:652 WARNING Shell command FAILED (exit code 1)' >> "${work}/easybuild-Tests.log"
printf '== run.py:650 INFO Shell command completed successfully\n\toutput will be logged to %s/eb-1/run-shell-cmd-output/ninja-2/out.txt\n== run.py:650 INFO Shell command completed successfully\n' "${ebtmp}" >> "${work}/easybuild-Sanity.log"
export EASYBUILD_TMPDIR="${ebtmp}"
printf 'Ok:                1   \nFail:              0   \n' > "${work}/obj/meson-logs/testlog.txt"
printf '#!/bin/bash\necho %s\n' "${work}/easybuild-Sanity.log" > "${work}/bin/eb"
compare "failed, sanity check after passing tests" failed 45 Sanity "${work}/logs"
printf 'Ok:                0   \nFail:              1   \n' > "${work}/obj/meson-logs/testlog.txt"
printf '#!/bin/bash\necho %s\n' "${work}/easybuild-Tests.log" > "${work}/bin/eb"
compare "failed, failing meson test" failed 1 Tests "${work}/logs"
unset EASYBUILD_TMPDIR
echo log > "${work}/easybuild-Slash.log"
printf '#!/bin/bash\necho %s\n' "${work}/easybuild-Slash.log" > "${work}/bin/eb"
compare "failed, LOGDIR with trailing slashes" failed 3 Slash "${work}/logs//"
printf '#!/bin/bash\nexit 0\n' > "${work}/bin/eb"
compare "rotate, no root" rotate --compress-after 3
compare "rotate, two roots" rotate a b
compare "rotate, unknown option" rotate "${work}" --bogus
compare "rotate, missing root" rotate "${work}/nope" --compress-after 3
compare "rotate, no compress" rotate "${work}/logs"
compare "rotate, bad compress" rotate "${work}/logs" --compress-after=x
compare "rotate, compress-after overflow" rotate "${work}/logs" --compress-after 18446744073709551616
compare "rotate, delete-after overflow" rotate "${work}/logs" --compress-after 5 --delete-after 18446744073709551616
compare "rotate, delete-after past a signed 64-bit integer" rotate "${work}/logs" --compress-after 5 --delete-after 9223372036854775808
mkdir -p "${work}/compress-overflow/20200101_000000"
echo old > "${work}/compress-overflow/20200101_000000/a.log"
compare "rotate, compress-after past a signed 64-bit integer" rotate "${work}/compress-overflow" --compress-after 9223372036854775808
compare "rotate, delete not later" rotate "${work}/logs" --compress-after 5 --delete-after 5
compare "rotate, empty delete" rotate "${work}/logs" --compress-after 5 --delete-after ""
compare "rotate, nothing to do" rotate "${work}/logs" --compress-after 5 --delete-after 9
compare "failed, bad syslog target" failed --syslog=bogus://x 1 Foo "${work}/logs"
compare "rotate, bad syslog target" rotate "${work}/logs" --compress-after 5 --syslog=bogus://x
EB_KEEP_LOGS_SYSLOG_PEN=0 compare "failed, bad syslog pen" failed 1 Foo "${work}/logs"
EB_KEEP_LOGS_SYSLOG_PEN=abc compare "rotate, bad syslog pen" rotate "${work}/logs" --compress-after 5
EB_KEEP_LOGS_NOW='' compare "rotate, empty EB_KEEP_LOGS_NOW" rotate "${work}/logs" --compress-after 5
# EB_KEEP_LOGS_NOW so far from a run's local midnight that the difference
# overflows a signed 64-bit integer, in each direction.
mkdir -p "${work}/now-overflow/20261001_120000"
echo old > "${work}/now-overflow/20261001_120000/a.log"
EB_KEEP_LOGS_NOW="-9223372036854775808" compare "rotate, EB_KEEP_LOGS_NOW far below a run" \
    rotate "${work}/now-overflow" --compress-after 5 --dry-run
mkdir -p "${work}/now-overflow-early/00010101_120000"
echo old > "${work}/now-overflow-early/00010101_120000/a.log"
EB_KEEP_LOGS_NOW="9223372036854775807" compare "rotate, EB_KEEP_LOGS_NOW far above a run" \
    rotate "${work}/now-overflow-early" --compress-after 5 --dry-run
mkdir -p "${work}/preview/20261001_120000/sub"
echo old > "${work}/preview/20261001_120000/a.log"
echo old > "${work}/preview/20261001_120000/sub/b.log"
echo old > "${work}/preview/20261001_120000/z.log"
echo old > "${work}/preview/20261001_120000/skip.log"
echo gz > "${work}/preview/20261001_120000/skip.log.gz"
echo link > "${work}/preview/20261001_120000/linked.log"
ln "${work}/preview/20261001_120000/linked.log" "${work}/preview/20261001_120000/linked.hardlink"
run_env=(PATH="${PATH}" EB_KEEP_LOGS_NOW="$(date -d 2026-11-13 +%s)")
compare "rotate, dry run" rotate "${work}/preview" --compress-after 5 --delete-after 90 --dry-run
compare "rotate, dry run with metrics-file" rotate "${work}/preview" --compress-after 5 --delete-after 90 --dry-run --metrics-file "${work}/dry.prom"
if [ -e "${work}/dry.prom" ] || [ -e "${work}/.dry.prom.lock" ]; then
    echo "DIFF rotate, dry run with metrics-file: wrote metrics or lock" >&2
    diffs=$((diffs + 1))
fi
compare "rotate, dry run with empty metrics-file" rotate "${work}/preview" --compress-after 5 --dry-run --metrics-file ""
EB_KEEP_LOGS_NOW="$(date -d 2026-11-13 +%s)" "${TOOL_BIN}" rotate "${work}/preview" --compress-after 5 --dry-run > "${work}/dry-parity-new.out" 2> "${work}/dry-parity-new.err"
{ echo "--- stdout"; cat "${work}/dry-parity-new.out"; echo "--- stderr"; cat "${work}/dry-parity-new.err"; } > "${work}/dry-parity.all"
expect "rotate, dry-run preview" "${work}/dry-parity.all"
dry_count=$(sed -nE 's/^eb-keep-logs rotate dry-run: ([0-9]+) files? would be compressed.*/\1/p' "${work}/dry-parity-new.out")
rot_out=$(EB_KEEP_LOGS_NOW="$(date -d 2026-11-13 +%s)" "${TOOL_BIN}" rotate "${work}/preview" --compress-after 5 2>/dev/null)
rot_count=$(sed -nE 's/^eb-keep-logs rotate: ([0-9]+) files? compressed.*/\1/p' <<< "${rot_out}")
if [ "${dry_count}" != "3" ] || [ "${dry_count}" != "${rot_count}" ]; then
    echo "DIFF rotate, dry-run count (${dry_count}) != rotate count (${rot_count})" >&2
    diffs=$((diffs + 1))
fi
run_env=(PATH="${PATH}")
compare "rotate, bad lock timeout" rotate "${work}/logs" --compress-after 5 --lock-timeout 1.5
compare "rotate, lock timeout without a value" rotate "${work}/logs" --compress-after 5 --lock-timeout
compare "rotate, empty lock timeout" rotate "${work}/logs" --compress-after 5 --lock-timeout=
exec {held}>>"${work}/logs/.eb-keep-logs-rotate.lock"
flock -n "${held}"
compare "rotate, lock held" rotate "${work}/logs" --compress-after 5 --lock-timeout 0
compare "rotate, lock held, zeros" rotate "${work}/logs/" --compress-after 5 --lock-timeout=00
exec {held}>&-
mkdir -p "${work}/symlock"
ln -s "${work}/nowhere" "${work}/symlock/.eb-keep-logs-rotate.lock"
compare "rotate, lock is a symbolic link" rotate "${work}/symlock" --compress-after 5
# A kill while compressing is not a race on a filename. The test-ops
# binary dies at EB_KEEP_LOGS_TEST_KILL_AT=mid-copy, before the compressed
# member is published. A second rotate then compresses the file.
mkdir -p "${work}/crash-new/20261001_120000"
printf 'log line\n' > "${work}/crash-new/20261001_120000/a.log"
EB_KEEP_LOGS_TEST_KILL_AT=mid-copy "${TEST_OPS_BIN:?TEST_OPS_BIN names the test-ops binary}" rotate "${work}/crash-new" --compress-after 5 >/dev/null 2>&1 || true
new_rerun=$("${TOOL_BIN}" rotate "${work}/crash-new" --compress-after 5 2>/dev/null)
new_count=$(sed -nE 's/^eb-keep-logs rotate: ([0-9]+) files? compressed.*/\1/p' <<< "${new_rerun}")
new_left=no; [ -e "${work}/crash-new/20261001_120000/a.log" ] && new_left=yes
printf 'compressed by the second rotate: %s\na.log left behind: %s\n' "${new_count}" "${new_left}" > "${work}/crash.all"
expect "rotate, killed mid-compress" "${work}/crash.all"
# The one run is past --delete-after, and another process writes into it.
mkdir -p "${work}/live/20261001_120000"
echo build > "${work}/live/20261001_120000/B.stdout.log"
(exec 3>>"${work}/live/20261001_120000/B.stdout.log" && : > "${work}/held" && exec sleep 60) &
holder=$!
until [ -e "${work}/held" ]; do sleep 0.05; done
compare "rotate, a run still written into" rotate "${work}/live" --compress-after 5 --delete-after 9
kill "${holder}"; wait "${holder}" 2>/dev/null

echo "${diffs} differences"
[ "${diffs}" -eq 0 ]
