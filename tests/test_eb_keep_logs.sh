#!/bin/bash
# Tests for eb-keep-logs with a stub eb. Run from the repository root:
#   bash tests/test_eb_keep_logs.sh
#   TOOL_BIN=/path/to/eb-keep-logs bash tests/test_eb_keep_logs.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
# TOOL_BIN runs the suite against another build of the tool.
tool="${TOOL_BIN:-${repo_root}/eb-keep-logs}"
unset EB_PIPELINE_LOG_DIR

fails=0
check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        echo "     expected: $3"
        echo "     got:      $2"
        fails=$((fails + 1))
    fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-test.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
count() { find "${work}/logs" -maxdepth 1 -type f -name "$1" | wc -l | tr -d ' '; }
mkdir -p "${work}/bin" "${work}/logs" "${work}/tmp"
echo "compile error: something" > "${work}/tmp/easybuild-Foo-1.0.log"
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
[ "\$1" = "--last-log" ] && echo "${work}/tmp/easybuild-Foo-1.0.log"
EOF
chmod +x "${work}/bin/eb"
PATH="${work}/bin:${PATH}"
# The stubs below model how these change EasyBuild's output.
unset COLUMNS EASYBUILD_OUTPUT_STYLE FORCE_COLOR

# failed: status 0 keeps nothing
"${tool}" failed 0 Foo-1.0-GCC-15.2.0 "${work}/logs" >/dev/null
check "success keeps nothing" "$(count '*')" "0"

# failed: the log is kept, intact, closed to others and listed
"${tool}" failed 1 Foo-1.0-GCC-15.2.0 "${work}/logs" >/dev/null
kept="${work}/logs/Foo-1.0-GCC-15.2.0.failed.ebout.log"
check "failure keeps the log" "$(cat "${kept}" 2>/dev/null)" "compile error: something"
check "kept log is closed to others" "$(stat -c '%A' "${kept}" | cut -c8-10)" "---"
check "kept log is in .licensed-logs" "$(cat "${work}/logs/.licensed-logs")" "$(realpath "${kept}")"

# failed: a retried build keeps the same files again, and each stays listed once
"${tool}" failed 1 Foo-1.0-GCC-15.2.0 "${work}/logs" >/dev/null
check "retry: the log is listed once" "$(cat "${work}/logs/.licensed-logs")" "$(realpath "${kept}")"
ebtmp="$(realpath "${work}")/ebtmp"
mkdir -p "${ebtmp}/eb-3/run-shell-cmd-output/make-3"
echo out > "${ebtmp}/eb-3/run-shell-cmd-output/make-3/out.txt"
echo err > "${ebtmp}/eb-3/run-shell-cmd-output/make-3/err.txt"
printf '    output (stdout + stderr) -> %s/eb-3/run-shell-cmd-output/make-3/out.txt\n' "${ebtmp}" > "${work}/logs/Retry-1.0.stdout.log"
for _ in 1 2; do
    EASYBUILD_TMPDIR="${ebtmp}" "${tool}" failed 1 Retry-1.0 "${work}/logs" >/dev/null
done
check "retry: the command output is kept" "$(count 'Retry-1.0.failed.command-*.txt')" "2"
check "retry: each kept file is listed once" "$(grep -c 'Retry-1.0' "${work}/logs/.licensed-logs")" "3"
# failed: a LOGDIR given with trailing slashes is named with one slash
check "trailing slash: one slash in the message" "$("${tool}" failed 1 Foo-1.0-GCC-15.2.0 "${work}/logs//")" "Failed build log: ${work}/logs/Foo-1.0-GCC-15.2.0.failed.ebout.log"

# failed: an explicit --tmp-logdir is passed on to eb --last-log
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
[ "\$1" = "--last-log" ] && [ "\$2" = "--tmp-logdir=${work}/explicit" ] && echo "${work}/tmp/easybuild-Foo-1.0.log"
EOF
"${tool}" failed 1 Exp-1.0 "${work}/logs" "${work}/explicit" >/dev/null
check "explicit tmp-logdir is used" "$(count 'Exp-1.0.failed.ebout.log')" "1"

# failed: EasyBuild 5 prints through rich, which wraps a path at COLUMNS, or
# at 80 columns when that is unset or FORCE_COLOR is set, unless the output
# style is basic
long="${work}/tmp/$(printf 'x%.0s' {1..100})"
mkdir -p "${long}"
echo "link error: wrapped" > "${long}/easybuild-Wrap-1.0.log"
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
[ "\$1" = "--last-log" ] || exit 0
width=\${COLUMNS:-80}
[ -n "\${FORCE_COLOR:-}" ] && width=80
if [[ " \$* " == *" --output-style=basic "* ]]; then
    echo "${long}/easybuild-Wrap-1.0.log"
else
    echo "${long}/easybuild-Wrap-1.0.log" | fold -w "\${width}"
fi
EOF
"${tool}" failed 1 Wrap-1.0 "${work}/logs" >/dev/null
check "wrapped path: log kept" "$(cat "${work}/logs/Wrap-1.0.failed.ebout.log" 2>/dev/null)" "link error: wrapped"
rm -f "${work}/logs/Wrap-1.0.failed.ebout.log"
FORCE_COLOR=1 COLUMNS=4096 "${tool}" failed 1 Wrap-1.0 "${work}/logs" >/dev/null
check "wrapped path with FORCE_COLOR: log kept" "$(cat "${work}/logs/Wrap-1.0.failed.ebout.log" 2>/dev/null)" "link error: wrapped"

# failed: an EasyBuild without output styles refuses --output-style
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
if [[ " \$* " == *" --output-style="* ]]; then
    echo "ERROR: Failed to parse configuration options: no such option: --output-style" >&2
    exit 1
fi
[ "\$1" = "--last-log" ] && echo "${work}/tmp/easybuild-Foo-1.0.log"
EOF
"${tool}" failed 1 Old-4.4 "${work}/logs" >/dev/null
check "eb without output styles: log kept" "$(count 'Old-4.4.failed.ebout.log')" "1"

# failed: why there is no log, when eb is missing or fails
mkdir -p "${work}/empty"
check "no eb on PATH: says so" "$(PATH="${work}/empty" "${tool}" failed 1 NoEb-1.0 "${work}/logs")" \
    "No EasyBuild log to keep for NoEb-1.0: eb is not on PATH."
printf '#!/bin/bash\nexit 3\n' > "${work}/bin/eb"
check "eb --last-log fails: says so" "$("${tool}" failed 1 Err-1.0 "${work}/logs")" \
    "No EasyBuild log to keep for Err-1.0: eb --last-log exited 3."
# failed: the build's stdout log and a TMP_LOGDIR under LOGDIR, where EasyBuild
# writes its own logs at 0644, are closed to others too
mkdir -p "${work}/run/easybuild-logs/Close-1.0" "${work}/elsewhere"
echo out > "${work}/run/Close-1.0.stdout.log"
echo log > "${work}/run/easybuild-logs/Close-1.0/easybuild-Close-1.0-20261116.003855.GStEt.log"
echo target > "${work}/elsewhere/target.log"
ln -s "${work}/elsewhere/target.log" "${work}/run/easybuild-logs/Close-1.0/link.log"
chmod 644 "${work}/run/Close-1.0.stdout.log" "${work}/run/easybuild-logs/Close-1.0/easybuild-Close-1.0-20261116.003855.GStEt.log" "${work}/elsewhere/target.log"
chmod 755 "${work}/run/easybuild-logs/Close-1.0" "${work}/elsewhere"
"${tool}" failed 0 Close-1.0 "${work}/run" "${work}/run/easybuild-logs/Close-1.0" >/dev/null
check "success: stdout log left as it is" "$(stat -c '%a' "${work}/run/Close-1.0.stdout.log")" "644"
"${tool}" failed 1 Close-1.0 "${work}/run" "${work}/run/easybuild-logs/Close-1.0" >/dev/null
check "stdout log closed to others" "$(stat -c '%a' "${work}/run/Close-1.0.stdout.log")" "640"
check "TMP_LOGDIR closed to others" "$(stat -c '%a' "${work}/run/easybuild-logs/Close-1.0")" "750"
check "logs in TMP_LOGDIR closed to others" "$(stat -c '%a' "${work}/run/easybuild-logs/Close-1.0/easybuild-Close-1.0-20261116.003855.GStEt.log")" "640"
check "a link in TMP_LOGDIR is not followed" "$(stat -c '%a' "${work}/elsewhere/target.log")" "644"
"${tool}" failed 1 Close-1.0 "${work}/run" "${work}/elsewhere" >/dev/null
check "TMP_LOGDIR outside LOGDIR left as it is" "$(stat -c '%a' "${work}/elsewhere")" "755"

# failed: no log from eb returns 0 and copies nothing
cat > "${work}/bin/eb" <<'EOF'
#!/bin/bash
exit 0
EOF
"${tool}" failed 2 Bar-2.0 "${work}/logs" >/dev/null
check "no log: returns 0" "$?" "0"
check "no log: nothing copied" "$(count 'Bar*')" "0"

# failed: eb names a path that does not exist
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
echo "${work}/tmp/gone.log"
EOF
"${tool}" failed 1 Baz-3.0 "${work}/logs" >/dev/null
check "missing file: nothing copied" "$(count 'Baz*')" "0"

# failed: the failing command's output is kept from inside EASYBUILD_TMPDIR,
# also when EASYBUILD_TMPDIR is reached through a symbolic link; when it is
# not kept, the reason is given
cmd="${work}/ebtmp/eb-1/run-shell-cmd-output/make-1"
mkdir -p "${cmd}" "${work}/elsewhere"
ln -s ebtmp "${work}/ebtmp-link"
echo "calc.c:6: error: 'scale' undeclared" > "${cmd}/out.txt"
printf '\toutput will be logged to %s/eb-1/run-shell-cmd-output/make-1/out.txt\n' "${work}/ebtmp-link" > "${work}/tmp/easybuild-Cmd-1.0.log"
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
[ "\$1" = "--last-log" ] && echo "${work}/tmp/easybuild-Cmd-1.0.log"
EOF
out_kept="${work}/logs/Cmd-1.0.failed.command-out.txt"
EASYBUILD_TMPDIR="${work}/ebtmp" "${tool}" failed 2 Cmd-1.0 "${work}/logs" >/dev/null
check "command output kept" "$(cat "${out_kept}" 2>/dev/null)" "calc.c:6: error: 'scale' undeclared"
rm -f "${out_kept}"
EASYBUILD_TMPDIR="${work}/ebtmp-link" "${tool}" failed 2 Cmd-1.0 "${work}/logs" >/dev/null
check "command output kept through a linked EASYBUILD_TMPDIR" "$(cat "${out_kept}" 2>/dev/null)" "calc.c:6: error: 'scale' undeclared"
rm -f "${out_kept}"
check "EASYBUILD_TMPDIR unset: says so" \
    "$(env -u EASYBUILD_TMPDIR "${tool}" failed 2 Cmd-1.0 "${work}/logs" | grep -v '^Failed build log')" \
    "Failed command output not kept: EASYBUILD_TMPDIR is not set."
check "outside EASYBUILD_TMPDIR: says so" \
    "$(EASYBUILD_TMPDIR="${work}/elsewhere" "${tool}" failed 2 Cmd-1.0 "${work}/logs" | grep -v '^Failed build log')" \
    "Failed command output not kept: ${work}/ebtmp-link/eb-1/run-shell-cmd-output/make-1/out.txt is not under EASYBUILD_TMPDIR."
check "command output not kept: nothing copied" "$(count 'Cmd-1.0.failed.command-*')" "0"
# failed: without TMP_LOGDIR, eb --last-log names the newest log in
# EasyBuild's default place, which can be another build's
printf '== processing EasyBuild easyconfig /ec/Ring-1.0.eb\nring test failed\n' > "${work}/tmp/easybuild-ring.log"
printf 'Command line: /ec/Calc-1.0.eb --robot\n== processing EasyBuild easyconfig /ec/Dep-2.0.eb\n' > "${work}/tmp/easybuild-calc.log"
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
[ "\$1" = "--last-log" ] && cat "${work}/tmp/last"
EOF
echo "${work}/tmp/easybuild-ring.log" > "${work}/tmp/last"
# The build's own stdout log still names its failing command.
mkdir -p "${work}/ebtmp/eb-2/run-shell-cmd-output/make-2"
echo "calc.c: error" > "${work}/ebtmp/eb-2/run-shell-cmd-output/make-2/out.txt"
echo "    output (stdout + stderr)  ->  ${work}/ebtmp/eb-2/run-shell-cmd-output/make-2/out.txt" > "${work}/logs/Calc-1.0.stdout.log"
check "another build's log: refused" "$(EASYBUILD_TMPDIR="${work}/ebtmp" "${tool}" failed 1 Calc-1.0 "${work}/logs")" \
    "No EasyBuild log to keep for Calc-1.0: ${work}/tmp/easybuild-ring.log is another build's log.
Failed command output: ${work}/logs/Calc-1.0.failed.command-out.txt"
check "another build's log: not copied" "$(count 'Calc-1.0.failed.ebout.log')" "0"
"${tool}" failed 1 Ring-1.0 "${work}/logs" >/dev/null
check "own log: kept" "$(count 'Ring-1.0.failed.ebout.log')" "1"
"${tool}" failed 1 Calc-1.0 "${work}/logs" "${work}/explicit" >/dev/null
check "with TMP_LOGDIR: not checked" "$(count 'Calc-1.0.failed.ebout.log')" "1"
rm -f "${work}/logs/Calc-1.0.failed.ebout.log"
echo "${work}/tmp/easybuild-calc.log" > "${work}/tmp/last"
"${tool}" failed 1 Calc-1.0 "${work}/logs" >/dev/null
check "own log, named on the command line: kept" "$(count 'Calc-1.0.failed.ebout.log')" "1"

# failed: a meson test step's testlog is kept, found across wrapped lines
mkdir -p "${work}/build/foo/easybuild_obj/meson-logs"
echo "---- tests::the_one stdout ----" > "${work}/build/foo/easybuild_obj/meson-logs/testlog.txt"
printf '  running shell command:\n        meson test -C\n%s/build/foo/easybuild_obj\n--print-errorlogs\n' "${work}" > "${work}/tmp/easybuild-Qux-4.0.log"
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
[ "\$1" = "--last-log" ] && echo "${work}/tmp/easybuild-Qux-4.0.log"
EOF
"${tool}" failed 1 Qux-4.0 "${work}/logs" >/dev/null
tl="${work}/logs/Qux-4.0.failed.meson-testlog.txt"
check "meson testlog kept" "$(cat "${tl}" 2>/dev/null)" "---- tests::the_one stdout ----"
check "meson testlog closed to others" "$(stat -c '%A' "${tl}" | cut -c8-10)" "---"
check "meson testlog listed" "$(grep -c 'Qux-4.0.failed.meson-testlog.txt' "${work}/logs/.licensed-logs")" "1"

# failed: the session log's last command output, and the meson testlog, are
# kept only when that command and those tests failed. EasyBuild 5.4.2 logs
# each command's out.txt, then "completed successfully" or "FAILED".
ebtmp="$(realpath "${work}")/ebtmp"
for cmd in meson-1 ninja-2 make-3; do
    mkdir -p "${ebtmp}/eb-1/run-shell-cmd-output/${cmd}"
    echo "${cmd} output" > "${ebtmp}/eb-1/run-shell-cmd-output/${cmd}/out.txt"
done
mkdir -p "${work}/build/sane/easybuild_obj/meson-logs" "${work}/build/broken/easybuild_obj/meson-logs"
printf 'Ok:                1   \nFail:              0   \n' > "${work}/build/sane/easybuild_obj/meson-logs/testlog.txt"
printf 'ring:wraparound FAIL\n\nOk:                0   \nFail:              1   \n' > "${work}/build/broken/easybuild_obj/meson-logs/testlog.txt"
command_log() {
    printf '\toutput will be logged to %s/eb-1/run-shell-cmd-output/meson-1/out.txt\n' "${ebtmp}"
    printf '\tmeson test -C %s/build/%s/easybuild_obj --print-errorlogs\n' "${work}" "$1"
    printf '== 2026-11-16 00:39:31,066 run.py:%s\n' "$2"
    [ "$#" -lt 3 ] || printf '\toutput will be logged to %s/eb-1/run-shell-cmd-output/%s/out.txt\n' "${ebtmp}" "$3"
    [ "$#" -lt 4 ] || printf '== 2026-11-16 00:39:31,399 run.py:%s\n' "$4"
}
command_log sane '650 INFO Shell command completed successfully' ninja-2 '650 INFO Shell command completed successfully' > "${work}/tmp/easybuild-Sane-1.0.log"
echo "== 2026-11-16 00:39:31,802 build_log.py:233 ERROR EasyBuild encountered an error: Sanity check failed: no file found at 'lib/libsane.so'" >> "${work}/tmp/easybuild-Sane-1.0.log"
command_log broken '652 WARNING Shell command FAILED (exit code 1)' > "${work}/tmp/easybuild-Broken-1.0.log"
command_log sane '650 INFO Shell command completed successfully' make-3 > "${work}/tmp/easybuild-Killed-1.0.log"
for n in Sane Broken Killed; do
    printf '#!/bin/bash\necho %s/tmp/easybuild-%s-1.0.log\n' "${work}" "${n}" > "${work}/bin/eb"
    EASYBUILD_TMPDIR="${ebtmp}" "${tool}" failed 1 "${n}-1.0" "${work}/logs" >/dev/null
done
check "sanity check failure: log kept" "$(count 'Sane-1.0.failed.ebout.log')" "1"
check "sanity check failure: no command output" "$(count 'Sane-1.0.failed.command-*')" "0"
check "sanity check failure: passing testlog not kept" "$(count 'Sane-1.0.failed.meson-testlog.txt')" "0"
check "failed meson test: its output kept" "$(cat "${work}/logs/Broken-1.0.failed.command-out.txt" 2>/dev/null)" "meson-1 output"
check "failed meson test: testlog kept" "$(tail -n 1 "${work}/logs/Broken-1.0.failed.meson-testlog.txt" 2>/dev/null)" "Fail:              1   "
check "build died in a command: its output kept" "$(cat "${work}/logs/Killed-1.0.failed.command-out.txt" 2>/dev/null)" "make-3 output"
# failed: EasyBuild 5.3 and later fold the --last-log path at 80 columns on a
# pipe, unless --output-style=basic is given
deep="${work}/tmp/scratch/easybuild/build-logs/20261113_235000/site-zen4/easybuild-logs/Long-1.0-GCC-15.2.0"
mkdir -p "${deep}"
echo "compile error: long path" > "${deep}/easybuild-Long-1.0-20261113.235959.log"
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
[ "\$1" = "--last-log" ] || exit 1
case " \$* " in
    *" --output-style=basic "*) echo "${deep}/easybuild-Long-1.0-20261113.235959.log" ;;
    *) echo "${deep}/easybuild-Long-1.0-20261113.235959.log" | fold -w 80 ;;
esac
EOF
"${tool}" failed 1 Long-1.0 "${work}/logs" >/dev/null
check "a log path longer than 80 columns is kept" "$(cat "${work}/logs/Long-1.0.failed.ebout.log" 2>/dev/null)" "compile error: long path"

# failed: an eb older than 4.5 refuses --output-style and does not fold
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
case " \$* " in *" --output-style="*) echo "eb: error: no such option: --output-style" >&2; exit 2 ;; esac
[ "\$1" = "--last-log" ] && echo "${work}/tmp/easybuild-Foo-1.0.log"
EOF
"${tool}" failed 1 Old-1.0 "${work}/logs" >/dev/null
check "an eb without --output-style still gives the log" "$(count 'Old-1.0.failed.ebout.log')" "1"

# failed: bad arguments are refused with exit 2
"${tool}" failed x Foo "${work}/logs" 2>/dev/null
check "non-numeric status refused" "$?" "2"
"${tool}" failed 1 Foo "${work}/nope" 2>/dev/null
check "missing logdir refused" "$?" "2"

# rotate: runs named by date; 'now' is fixed at 2026-11-13
root="${work}/root"
mkdir -p "${root}/20261001_120000/site-zen4" "${root}/20261110_120000" "${root}/20260801_090000" "${root}/notarun"
echo old > "${root}/20261001_120000/site-zen4/A.stdout.log"
echo secret > "${root}/20261001_120000/site-zen4/B.failed.ebout.log"
chmod 640 "${root}/20261001_120000/site-zen4/B.failed.ebout.log"
realpath "${root}/20261001_120000/site-zen4/B.failed.ebout.log" > "${root}/20261001_120000/site-zen4/.licensed-logs"
echo recent > "${root}/20261110_120000/C.stdout.log"
echo ancient > "${root}/20260801_090000/D.stdout.log"
echo other > "${root}/notarun/E.log"
EB_KEEP_LOGS_NOW=$(date -d 2026-11-13 +%s)
export EB_KEEP_LOGS_NOW

"${tool}" rotate "${root}" --compress-after 30 >/dev/null
check "old run compressed" "$(ls "${root}/20261001_120000/site-zen4" | sort | tr '\n' ' ')" "A.stdout.log.gz B.failed.ebout.log.gz "
check "compressed content intact" "$(zcat "${root}/20261001_120000/site-zen4/A.stdout.log.gz")" "old"
check "closed log stays closed" "$(stat -c '%A' "${root}/20261001_120000/site-zen4/B.failed.ebout.log.gz" | cut -c8-10)" "---"
check ".licensed-logs follows" "$(cat "${root}/20261001_120000/site-zen4/.licensed-logs")" "$(realpath "${root}/20261001_120000/site-zen4")/B.failed.ebout.log.gz"
check "recent run untouched" "$(ls "${root}/20261110_120000")" "C.stdout.log"
check "non-run directory untouched" "$(ls "${root}/notarun")" "E.log"
check "no deletion without --delete-after" "$(ls -d "${root}/20260801_090000" 2>/dev/null | wc -l | tr -d ' ')" "1"

check "one run deleted, singular" "$("${tool}" rotate "${root}" --compress-after 30 --delete-after 90)" "eb-keep-logs rotate: 0 files compressed, 1 run deleted under ${root}"
check "run past --delete-after deleted" "$(ls -d "${root}/20260801_090000" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "run inside --delete-after kept" "$(ls -d "${root}/20261001_120000" 2>/dev/null | wc -l | tr -d ' ')" "1"

mkdir -p "${work}/one/20261001_120000"
echo one > "${work}/one/20261001_120000/F.stdout.log"
check "one file compressed, singular" "$("${tool}" rotate "${work}/one" --compress-after 30)" "eb-keep-logs rotate: 1 file compressed, 0 runs deleted under ${work}/one"

"${tool}" rotate "${root}" --compress-after 30 --delete-after 10 2>/dev/null
check "delete before compress refused" "$?" "2"
"${tool}" rotate "${root}" 2>/dev/null
check "rotate without --compress-after refused" "$?" "2"

# --help: what `failed` copies, and the variable `rotate` reads
check "help: the copy is the session log" "$("${tool}" --help | grep -c 'EasyBuild session log')" "1"
check "help: EB_KEEP_LOGS_NOW" "$("${tool}" --help | grep -c 'EB_KEEP_LOGS_NOW')" "1"
# rotate: the run rotate writes into is still going and is left alone. A run
# that started before midnight is a day old just after it.
next_day=$(date -d '2026-11-14 00:10' +%s)
lsrun() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' '; }
mkrun() {
    mkdir -p "$1/20261113_235000/site-zen4" "$1/20261110_120000"
    echo build > "$1/20261113_235000/site-zen4/F.stdout.log"
    echo older > "$1/20261110_120000/G.stdout.log"
}

own="${work}/own"
mkrun "${own}"
log="${own}/20261113_235000/site-zen4/rotate.log"
EB_KEEP_LOGS_NOW=${next_day} "${tool}" rotate "${own}" --compress-after 1 > "${log}" 2>&1
check "own run: rotate.log stays open" "$(cat "${log}" 2>/dev/null)" "eb-keep-logs rotate: 1 file compressed, 0 runs deleted under ${own}"
check "own run: not compressed" "$(lsrun "${own}/20261113_235000/site-zen4")" "F.stdout.log rotate.log "
check "own run: an older run compressed" "$(lsrun "${own}/20261110_120000")" "G.stdout.log.gz "

gone="${work}/gone"
mkrun "${gone}"
log="${gone}/20261113_235000/site-zen4/rotate.log"
EB_KEEP_LOGS_NOW=$(date -d '2026-11-16 00:10' +%s) "${tool}" rotate "${gone}" --compress-after 1 --delete-after 2 > "${log}" 2>&1
check "own run past --delete-after: kept" "$(lsrun "${gone}/20261113_235000/site-zen4")" "F.stdout.log rotate.log "
check "own run past --delete-after: an older run deleted" "$(lsrun "${gone}")" "20261113_235000 "

# Through srun the output reaches rotate.log over a pipe; eb-pipeline exports
# the run's log directory as EB_PIPELINE_LOG_DIR.
piped="${work}/piped"
mkrun "${piped}"
log_dir="${piped}/20261113_235000/site-zen4"
EB_PIPELINE_LOG_DIR=${log_dir} EB_KEEP_LOGS_NOW=${next_day} "${tool}" rotate "${piped}" --compress-after 1 2>&1 | cat > "${log_dir}/rotate.log"
check "own run through a pipe: not compressed" "$(lsrun "${log_dir}")" "F.stdout.log rotate.log "
EB_KEEP_LOGS_NOW=${next_day} "${tool}" rotate "${piped}" --compress-after 1 > /dev/null 2>&1
check "a finished run is compressed" "$(lsrun "${log_dir}")" "F.stdout.log.gz rotate.log.gz "

# rotate: an empty EB_KEEP_LOGS_NOW is the current time, as an unset one is
now_root="${work}/now"
old_run="$(TZ=UTC date -d '40 days ago' +%Y%m%d)_000000"
young_run="$(TZ=UTC date -d '20 days ago' +%Y%m%d)_000000"
mkdir -p "${now_root}/${old_run}" "${now_root}/${young_run}"
echo old > "${now_root}/${old_run}/H.stdout.log"
echo young > "${now_root}/${young_run}/I.stdout.log"
check "empty EB_KEEP_LOGS_NOW: the current time" \
    "$(TZ=UTC EB_KEEP_LOGS_NOW='' "${tool}" rotate "${now_root}" --compress-after 30 2>&1)" \
    "eb-keep-logs rotate: 1 file compressed, 0 runs deleted under ${now_root}"
check "empty EB_KEEP_LOGS_NOW: the run 40 days old compressed" "$(lsrun "${now_root}/${old_run}")" "H.stdout.log.gz "

# rotate: with ENV, a run's local midnight is the one date(1) gives. Thirty
# days after it the run is 30 days old, and 29 a second before.
zoned() {
    local label=$1 midnight
    shift
    rm -rf "${work}/zoned"
    mkdir -p "${work}/zoned/20261101_000000"
    echo log > "${work}/zoned/20261101_000000/J.stdout.log"
    midnight=$(env "$@" date -d 20261101 +%s)
    env "$@" EB_KEEP_LOGS_NOW=$((midnight + 30 * 86400 - 1)) "${tool}" rotate "${work}/zoned" --compress-after 30 >/dev/null
    check "${label}: 29 days old a second before date's midnight" "$(lsrun "${work}/zoned/20261101_000000")" "J.stdout.log "
    env "$@" EB_KEEP_LOGS_NOW=$((midnight + 30 * 86400)) "${tool}" rotate "${work}/zoned" --compress-after 30 >/dev/null
    check "${label}: 30 days old at date's midnight" "$(lsrun "${work}/zoned/20261101_000000")" "J.stdout.log.gz "
}
zoned "TZ naming a zone file" TZ=Asia/Tokyo
zoned "TZDIR empty" TZDIR= TZ=Asia/Tokyo
zoned "TZ ':' then a rule string" TZ=':AEST-10AEDT,M10.1.0,M4.1.0/3'

if [ "${fails}" -ne 0 ]; then echo "${fails} failed"; exit 1; fi
echo "all passed"
