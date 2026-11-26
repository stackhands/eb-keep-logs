#!/bin/bash
# Tests for eb-keep-logs with a stub eb. Run from the repository root:
#   bash tests/test_eb_keep_logs.sh
#   TOOL_BIN=/path/to/eb-keep-logs bash tests/test_eb_keep_logs.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
# TOOL_BIN runs the suite against another build of the tool.
tool="${TOOL_BIN:?TOOL_BIN names the eb-keep-logs binary}"
unset EB_PIPELINE_LOG_DIR

fails=0
# shellcheck source=tests/lib/check.sh
. "${repo_root}/tests/lib/check.sh"

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
# One table of (COLUMNS, FORCE_COLOR): unset, and FORCE_COLOR with a wide COLUMNS.
wrap_miss=
for row in unset force; do
    rm -f "${work}/logs/Wrap-1.0.failed.ebout.log"
    case "${row}" in
        unset) "${tool}" failed 1 Wrap-1.0 "${work}/logs" >/dev/null ;;
        force) FORCE_COLOR=1 COLUMNS=4096 "${tool}" failed 1 Wrap-1.0 "${work}/logs" >/dev/null ;;
    esac
    [ "$(cat "${work}/logs/Wrap-1.0.failed.ebout.log" 2>/dev/null)" = "link error: wrapped" ] || wrap_miss+="${row} "
done
check "wrapped path: log kept" "${wrap_miss}" ""

# failed: eb stubs that reject --output-style still give the log.
# Old-4.4 is the parser error; Old-1.0 is an older eb.
style_miss=
for name in Old-4.4 Old-1.0; do
    case "${name}" in
        Old-4.4)
            cat > "${work}/bin/eb" <<EOF
#!/bin/bash
if [[ " \$* " == *" --output-style="* ]]; then
    echo "ERROR: Failed to parse configuration options: no such option: --output-style" >&2
    exit 1
fi
[ "\$1" = "--last-log" ] && echo "${work}/tmp/easybuild-Foo-1.0.log"
EOF
            ;;
        Old-1.0)
            cat > "${work}/bin/eb" <<EOF
#!/bin/bash
case " \$* " in *" --output-style="*) echo "eb: error: no such option: --output-style" >&2; exit 2 ;; esac
[ "\$1" = "--last-log" ] && echo "${work}/tmp/easybuild-Foo-1.0.log"
EOF
            ;;
    esac
    "${tool}" failed 1 "${name}" "${work}/logs" >/dev/null
    [ "$(count "${name}.failed.ebout.log")" = 1 ] || style_miss+="${name} "
done
check "eb without output styles: log kept" "${style_miss}" ""

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
# One table of EASYBUILD_TMPDIR: the real path, then the symlink.
tmp_miss=
for tmp in "${work}/ebtmp" "${work}/ebtmp-link"; do
    rm -f "${out_kept}"
    EASYBUILD_TMPDIR="${tmp}" "${tool}" failed 2 Cmd-1.0 "${work}/logs" >/dev/null
    [ "$(cat "${out_kept}" 2>/dev/null)" = "calc.c:6: error: 'scale' undeclared" ] || tmp_miss+="${tmp} "
done
check "command output kept" "${tmp_miss}" ""
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
# In a UTF-8 locale grep stops a PCRE path at an invalid byte. The Zig
# reader must not continue through that byte and file a different testlog.
nonutf=$'\xff'
mkdir -p "${work}/build/nonutf${nonutf}/meson-logs"
printf 'Ok: 0\nFail: 1\n' > "${work}/build/nonutf${nonutf}/meson-logs/testlog.txt"
printf 'meson test -C %s/build/nonutf%s\n' "${work}" "${nonutf}" > "${work}/tmp/easybuild-NonUtf-1.0.log"
printf '#!/bin/bash\necho %s/tmp/easybuild-NonUtf-1.0.log\n' "${work}" > "${work}/bin/eb"
LC_ALL=C.UTF-8 "${tool}" failed 1 NonUtf-1.0 "${work}/logs" >/dev/null
check "non-UTF-8 meson path in a UTF-8 locale is stopped" "$(count 'NonUtf-1.0.failed.meson-testlog.txt')" "0"
LC_ALL=C "${tool}" failed 1 NonUtfC-1.0 "${work}/logs" >/dev/null
check "non-UTF-8 meson path in the C locale is kept" "$(count 'NonUtfC-1.0.failed.meson-testlog.txt')" "1"
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

check "dry run: lists files and runs without changing them" \
    "$("${tool}" rotate "${root}" --compress-after 30 --delete-after 90 --dry-run)" \
    "delete ${root}/20260801_090000
compress $(realpath "${root}/20261001_120000/site-zen4")/A.stdout.log
compress $(realpath "${root}/20261001_120000/site-zen4")/B.failed.ebout.log
eb-keep-logs rotate dry-run: 2 files would be compressed, 1 run would be deleted under ${root}"
check "dry run: files and runs stay in place" \
    "$(find "${root}" -name '*.gz' -o -name 'D.stdout.log' | LC_ALL=C sort | tr '\n' ' ')" \
    "${root}/20260801_090000/D.stdout.log "
lock_missing=1
test -e "${root}/.eb-keep-logs-rotate.lock" && lock_missing=0
check "dry run: creates no lock" "$lock_missing" "1"

skip_root="${work}/dry-skip"
mkdir -p "${skip_root}/20261001_120000/sub"
printf 'a\n' > "${skip_root}/20261001_120000/a.log"
printf 'b\n' > "${skip_root}/20261001_120000/sub/b.log"
printf 'z\n' > "${skip_root}/20261001_120000/z.log"
printf 's\n' > "${skip_root}/20261001_120000/skip.log"
printf 'gz\n' > "${skip_root}/20261001_120000/skip.log.gz"
printf 'l\n' > "${skip_root}/20261001_120000/link.log"
ln "${skip_root}/20261001_120000/link.log" "${skip_root}/20261001_120000/link.hard"
skip_real=$(realpath "${skip_root}/20261001_120000")
check "dry run: sorted across subdirs and skips .gz and hard links" \
    "$("${tool}" rotate "${skip_root}" --compress-after 30 --dry-run)" \
    "compress ${skip_real}/a.log
compress ${skip_real}/sub/b.log
compress ${skip_real}/z.log
eb-keep-logs rotate dry-run: 3 files would be compressed, 0 runs would be deleted under ${skip_root}"

"${tool}" rotate "${root}" --compress-after 30 >/dev/null
check "old run compressed" "$(ls "${root}/20261001_120000/site-zen4" | sort | tr '\n' ' ')" "A.stdout.log.gz B.failed.ebout.log.gz "
check "compressed content intact" "$(zcat "${root}/20261001_120000/site-zen4/A.stdout.log.gz")" "old"
check "closed log stays closed" "$(stat -c '%A' "${root}/20261001_120000/site-zen4/B.failed.ebout.log.gz" | cut -c8-10)" "---"
check ".licensed-logs follows" "$(cat "${root}/20261001_120000/site-zen4/.licensed-logs")" "$(realpath "${root}/20261001_120000/site-zen4")/B.failed.ebout.log.gz"
check ".licensed-logs follows: no temporary file left" "$(find "${root}/20261001_120000" -name '.licensed-logs?*' | wc -l)" "0"
# The new list is written to a file of its own beside the old one, not
# through a symbolic link planted at a fixed name.
planted="${work}/planted/20261001_120000/site-zen4"
mkdir -p "${planted}"
echo log > "${planted}/P.stdout.log"
realpath "${planted}/P.stdout.log" > "${planted}/.licensed-logs"
chmod 640 "${planted}/.licensed-logs"
echo victim > "${work}/victim"
ln -s "${work}/victim" "${planted}/.licensed-logs.tmp"
"${tool}" rotate "${work}/planted" --compress-after 30 >/dev/null 2>&1
check "a link beside a list: not written through" "$(cat "${work}/victim")" "victim"
check "a link beside a list: the list replaced" "$(stat -c '%F %a' "${planted}/.licensed-logs"): $(cat "${planted}/.licensed-logs")" \
    "regular file 640: $(realpath "${planted}")/P.stdout.log.gz"
# A list its owner may not write is still replaced, and keeps its mode.
ro="${work}/ro/20261001_120000"
mkdir -p "${ro}"
echo log > "${ro}/Q.stdout.log"
realpath "${ro}/Q.stdout.log" > "${ro}/.licensed-logs"
chmod 444 "${ro}/.licensed-logs"
"${tool}" rotate "${work}/ro" --compress-after 30 >/dev/null 2>&1
check "a list its owner may not write: replaced, mode kept" \
    "$(stat -c '%a' "${ro}/.licensed-logs"): $(cat "${ro}/.licensed-logs")" "444: $(realpath "${ro}")/Q.stdout.log.gz"
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
# --help lists every option the parser takes: the words starting with -
# that its comparisons of an argument name, or its optionValue calls, which
# take NAME and NAME=, name. An option that takes a value gives its default or says it is
# required, and the exit statuses are listed.
"${tool}" --help > "${work}/help"
options=$({
    grep -ohE '\(u8, [a-z_]+, "-[^"]*"\)' "${repo_root}"/src/*.zig | cut -d '"' -f 2
    grep -ohE 'optionValue\([a-z_]+, &[a-z_]+, "-[^"]*"' "${repo_root}"/src/*.zig | cut -d '"' -f 2 | sed 'p; s/$/=/'
} | LC_ALL=C sort -u)
# listed OPT: whether --help names OPT as a word, or OPT= followed by a value.
listed() {
    case "$1" in
        *=) grep -qE -- "(^|[[ ,|])$1[A-Z]" "${work}/help" ;;
        *) grep -qE -- "(^|[[ ,|])$1(\$|[] ,|])" "${work}/help" ;;
    esac
}
# entry OPT: the line of --help that starts with OPT and the lines indented
# under it.
entry() {
    awk -v opt="$1 " '
        { match($0, /^ */) }
        found && RLENGTH <= depth { exit }
        found { print }
        !found && substr($0, RLENGTH + 1, length(opt)) == opt { found = 1; depth = RLENGTH; print }
    ' "${work}/help"
}
check "help: lists every option" "$(for opt in ${options}; do listed "${opt}" || echo "${opt}"; done)" ""
check "help: each option with a value gives its default" \
    "$(for opt in ${options}; do [[ "${opt}" != *= ]] || [ "$(entry "${opt%=}" | grep -cE 'Default: |Required')" = 1 ] || echo "${opt%=}"; done)" ""
check "help: --lock-timeout waits 600 s by default" "$(entry --lock-timeout | grep -c 'Default: 600;')" "1"
check "help: exit statuses" "$(sed -n '/^Exit status:$/,$p' "${work}/help" | grep -oE '^  [0-9]+ ' | tr -d ' ' | tr '\n' ' ')" "0 2 75 "
# --help: the reference diff is the contract.
# whole: the last line of each paragraph that does not end with a full stop,
# then the first two words of the last paragraph. No arguments are whole when
# that is only "Exit status:".
whole() { awk -v RS= '{ n = split($0, line, "\n"); if (line[n] !~ /\.$/) print line[n]; last = $1 " " $2 } END { print last }'; }
"${tool}" > "${work}/usage"
check "help: no arguments print it whole, with exit 2" "$?: $(whole < "${work}/usage")" "2: Exit status:"
# eb-pipeline passes --lock-timeout where `--help` exits 0 and names it.
check "help: as eb-pipeline reads it" "$("${tool}" --help | grep -c -- --lock-timeout > /dev/null; echo "${PIPESTATUS[*]}")" "0 0"
# The example under "*** --help" in the cli reference is the usage as printed.
reference_help=$(awk '
    /^\*\*\* / { in_help = ($0 == "*** --help") }
    in_help && /^#\+end_example$/ { exit }
    shown { print }
    in_help && /^#\+begin_example$/ { shown = 1 }
' "${repo_root}/docs/orgmode/reference/cli.org")
check "help: as the cli reference shows it" "$(
    diff <(printf '%s\n' "${reference_help}") "${work}/help"
    diff <(printf '%s\n' "${reference_help}") <("${tool}" -h)
)" ""
# rotate: the run rotate writes into is still going and is left alone. A run
# that started before midnight is a day old just after it.
next_day=$(date -d '2026-11-14 00:10' +%s)
lsrun() { find "$1" -mindepth 1 -maxdepth 1 ! -name .eb-keep-logs-rotate.lock -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '; }
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

# rotate: a build of another run, started before midnight UTC, is still
# going: EasyBuild holds its session log open for writing, and copies it to
# the installation at the end. rotate runs from a run started after midnight.
# hold MODE FILE: a process that holds FILE open, for writing with >> and for
# reading with <, until it is killed; its PID is in ${holder}.
hold() {
    rm -f "${work}/held"
    case "$1" in
        '>>') (exec 3>>"$2" && : > "${work}/held" && exec sleep 60) & ;;
        '<') (exec 3<"$2" && : > "${work}/held" && exec sleep 60) & ;;
    esac
    holder=$!
    until [ -e "${work}/held" ]; do sleep 0.05; done
}
utc_next_day=$(TZ=UTC date -d '2026-11-14 00:10' +%s)
live="${work}/live"
live_dir="${live}/20261113_235000/site-zen3/easybuild-logs/Foo-1.0"
mkdir -p "${live_dir}" "${live}/20261114_000500/site-zen4" "${live}/20261001_120000"
echo started > "${live_dir}/easybuild-Foo-1.0-20261113.235001.log"
echo build > "${live}/20261113_235000/site-zen3/Foo-1.0.stdout.log"
echo older > "${live}/20261001_120000/G.stdout.log"
hold '>>' "${live_dir}/easybuild-Foo-1.0-20261113.235001.log"
log="${live}/20261114_000500/site-zen4/rotate.log"
TZ=UTC EB_KEEP_LOGS_NOW=${utc_next_day} "${tool}" rotate "${live}" --compress-after 1 > "${log}" 2>&1
check "a build still going in another run: its log left alone" "$(lsrun "${live_dir}")" "easybuild-Foo-1.0-20261113.235001.log "
check "a build still going in another run: nothing in its run compressed" \
    "$(lsrun "${live}/20261113_235000/site-zen3")" "Foo-1.0.stdout.log easybuild-logs "
check "a build still going in another run: an older run compressed" "$(lsrun "${live}/20261001_120000")" "G.stdout.log.gz "
check "a build still going in another run: rotate's summary" "$(cat "${log}")" \
    "eb-keep-logs rotate: 1 file compressed, 0 runs deleted under ${live}"
kill "${holder}"; wait "${holder}" 2>/dev/null
TZ=UTC EB_KEEP_LOGS_NOW=${utc_next_day} "${tool}" rotate "${live}" --compress-after 1 > /dev/null 2>&1
check "a build that has ended: its run compressed" "$(lsrun "${live_dir}")$(lsrun "${live}/20261113_235000/site-zen3")" \
    "easybuild-Foo-1.0-20261113.235001.log.gz Foo-1.0.stdout.log.gz easybuild-logs "

# A process that only reads a run's logs does not hold the run back.
read_root="${work}/read"
mkdir -p "${read_root}/20261113_235000"
echo build > "${read_root}/20261113_235000/R.stdout.log"
hold '<' "${read_root}/20261113_235000/R.stdout.log"
TZ=UTC EB_KEEP_LOGS_NOW=${utc_next_day} "${tool}" rotate "${read_root}" --compress-after 1 > /dev/null 2>&1
check "a run a process only reads: compressed" "$(lsrun "${read_root}/20261113_235000")" "R.stdout.log.gz "
kill "${holder}"; wait "${holder}" 2>/dev/null

# Nor is a run that is still written into deleted past --delete-after.
gone_live="${work}/gone-live"
mkdir -p "${gone_live}/20261001_120000" "${gone_live}/20261002_120000"
echo hung > "${gone_live}/20261001_120000/H.stdout.log"
echo ended > "${gone_live}/20261002_120000/I.stdout.log"
hold '>>' "${gone_live}/20261001_120000/H.stdout.log"
TZ=UTC EB_KEEP_LOGS_NOW=${utc_next_day} "${tool}" rotate "${gone_live}" --compress-after 1 --delete-after 30 > /dev/null 2>&1
check "a run still written into past --delete-after: kept as it is" "$(lsrun "${gone_live}")$(lsrun "${gone_live}/20261001_120000")" \
    "20261001_120000 H.stdout.log "
kill "${holder}"; wait "${holder}" 2>/dev/null

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

# rotate: with ENV, a run's local midnight is the one GNU date gives, and the
# tool runs with GNU date as date. Thirty days after it the run is 30 days
# old, and 29 a second before. Ubuntu's date is uutils' from 25.10, GNU's
# being gnudate; uutils' reads as UTC some TZ rule strings that glibc reads.
gnu_date=
for d in date gnudate; do
    if "${d}" --version 2>/dev/null | grep -q '(GNU coreutils)'; then
        gnu_date=$(command -v "${d}")
        mkdir -p "${work}/gnu"
        ln -s "${gnu_date}" "${work}/gnu/date"
        break
    fi
done
zoned() {
    local label=$1 midnight
    shift
    if [ -z "${gnu_date}" ]; then
        echo "skip ${label}: no GNU date to compare with" >&2
        return
    fi
    rm -rf "${work}/zoned"
    mkdir -p "${work}/zoned/20261101_000000"
    echo log > "${work}/zoned/20261101_000000/J.stdout.log"
    midnight=$(env "$@" "${gnu_date}" -d 20261101 +%s)
    set -- PATH="${work}/gnu:${PATH}" "$@"
    env "$@" EB_KEEP_LOGS_NOW=$((midnight + 30 * 86400 - 1)) "${tool}" rotate "${work}/zoned" --compress-after 30 >/dev/null
    check "${label}: 29 days old a second before date's midnight" "$(lsrun "${work}/zoned/20261101_000000")" "J.stdout.log "
    env "$@" EB_KEEP_LOGS_NOW=$((midnight + 30 * 86400)) "${tool}" rotate "${work}/zoned" --compress-after 30 >/dev/null
    check "${label}: 30 days old at date's midnight" "$(lsrun "${work}/zoned/20261101_000000")" "J.stdout.log.gz "
}
zoned "TZ naming a zone file" TZ=Asia/Tokyo
zoned "TZDIR empty" TZDIR= TZ=Asia/Tokyo
zoned "TZ ':' then a rule string" TZ=':AEST-10AEDT,M10.1.0,M4.1.0/3'
zoned "TZ rule string with text after it" TZ='CET-1CEST,M3.5.0,M10.5.0/3x'
zoned "TZ rule string without an end rule" TZ='CET-1CEST,M3.5.0'

# rotate: a run's age is its name's, not its directory's mtime. A chmod
# leaves the mtime and compressing the logs in the run moves it.
mt_root="${work}/mtime"
mkdir -p "${mt_root}/20261001_120000" "${mt_root}/20261110_120000"
echo old > "${mt_root}/20261001_120000/K.stdout.log"
echo young > "${mt_root}/20261110_120000/L.stdout.log"
touch -d '2026-10-01 12:00' "${mt_root}/20261001_120000"
touch -d '2020-01-01 00:00' "${mt_root}/20261110_120000"
set_mtime=$(date -d '2026-10-01 12:00' +%s)
chmod o-rwx "${mt_root}/20261001_120000"
check "chmod leaves a run's mtime" "$(stat -c %Y "${mt_root}/20261001_120000")" "${set_mtime}"
"${tool}" rotate "${mt_root}" --compress-after 30 >/dev/null
check "compressing a run's logs moves its mtime" \
    "$([ "$(stat -c %Y "${mt_root}/20261001_120000")" != "${set_mtime}" ] && echo moved)" "moved"
check "an old mtime on a young run: not compressed" "$(lsrun "${mt_root}/20261110_120000")" "L.stdout.log "
"${tool}" rotate "${mt_root}" --compress-after 30 --delete-after 40 >/dev/null
check "a new mtime on an old run: deleted" "$(lsrun "${mt_root}")" "20261110_120000 "

# rotate: one rotate of a tree at a time, holding ROOT/.eb-keep-logs-rotate.lock
lk_root="${work}/locked"
lock="${lk_root}/.eb-keep-logs-rotate.lock"
mkdir -p "${lk_root}/20261001_120000"
echo old > "${lk_root}/20261001_120000/M.stdout.log"
exec {held}>>"${lock}"
flock -n "${held}"
check "lock held: refused at once" "$("${tool}" rotate "${lk_root}" --compress-after 30 --lock-timeout 0 2>&1; echo "exit $?")" \
    "eb-keep-logs: another rotate holds the lock ${lock}; gave up after 0 s (--lock-timeout)
exit 75"
check "lock held: nothing compressed" "$(lsrun "${lk_root}/20261001_120000")" "M.stdout.log "
mono_ns() { python3 -c 'import time; print(time.monotonic_ns())'; }
start=$(mono_ns)
"${tool}" rotate "${lk_root}" --compress-after 30 --lock-timeout=1 > /dev/null 2>&1
rc=$?
elapsed=$(( $(mono_ns) - start ))
# 50 ms early allowance on a monotonic clock. `--lock-timeout` stays 1 s.
check "lock held: refused after --lock-timeout" "${rc}:$(( elapsed + 50000000 >= 1000000000 ))" "75:1"
"${tool}" rotate "${lk_root}" --compress-after 30 > "${work}/letgo.out" 2>&1 &
letgo=$!
flock -u "${held}"
wait "${letgo}"
check "lock let go: the waiting rotate rotates" "$(cat "${work}/letgo.out")" \
    "eb-keep-logs rotate: 1 file compressed, 0 runs deleted under ${lk_root}"
exec {held}>&-
check "the lock stays in ROOT" "$(stat -c '%F' "${lock}")" "regular empty file"
chmod 444 "${lock}"
exec {held}<"${lock}"
flock -n "${held}"
check "a lock this user may only read: still taken" "$("${tool}" rotate "${lk_root}" --compress-after 30 --lock-timeout 0 >/dev/null 2>&1; echo $?)" "75"
exec {held}<&-
check "a lock this user may only read: rotate runs" "$("${tool}" rotate "${lk_root}" --compress-after 30 2>&1)" \
    "eb-keep-logs rotate: 0 files compressed, 0 runs deleted under ${lk_root}"
chmod 644 "${lock}"
"${tool}" rotate "${lk_root}" --compress-after 30 --lock-timeout x 2>/dev/null
check "non-numeric --lock-timeout refused" "$?" "2"
"${tool}" rotate "${lk_root}" --compress-after 30 --lock-timeout 2>/dev/null
check "--lock-timeout without a value refused" "$?" "2"
mkdir -p "${work}/symlock"
ln -s "${work}/nowhere" "${work}/symlock/.eb-keep-logs-rotate.lock"
"${tool}" rotate "${work}/symlock" --compress-after 30 >/dev/null 2>&1
check "a symbolic link at the lock: refused" "$?" "2"
check "a symbolic link at the lock: not followed" "$(find "${work}" -maxdepth 1 -name nowhere | wc -l)" "0"
# A flock(1) on PATH that reports a file system that cannot lock; the
# binary calls flock(2), which locks here.
mkdir -p "${work}/nolock-bin" "${work}/nolock/20261001_120000"
printf '#!/bin/sh\necho "flock: 3: Function not implemented" >&2\nexit 65\n' > "${work}/nolock-bin/flock"
chmod +x "${work}/nolock-bin/flock"
real_gzip=$(command -v gzip)
cat > "${work}/nolock-bin/gzip" << EOF
#!/bin/bash
# First gzip of each rotate waits until the other has entered, so both
# are inside the update together. Then the real gzip runs. The second
# rotate writes a regular file and the first polls for it.
barrier=\${EB_KEEP_LOGS_BARRIER:-}
if [ -n "\${barrier}" ] && mkdir "\${barrier}/seen.\${PPID}" 2>/dev/null; then
    if mkdir "\${barrier}/lead" 2>/dev/null; then
        deadline=\$((SECONDS + 15))
        while [ ! -e "\${barrier}/go" ]; do
            [ "\${SECONDS}" -ge "\${deadline}" ] && break
            sleep 0.05
        done
    else
        : > "\${barrier}/go"
    fi
fi
exec ${real_gzip} "\$@"
EOF
chmod +x "${work}/nolock-bin/gzip"
echo old > "${work}/nolock/20261001_120000/N.stdout.log"
check "a file system that cannot lock: rotates without the lock" \
    "$(PATH="${work}/nolock-bin:${PATH}" "${tool}" rotate "${work}/nolock" --compress-after 30 2>/dev/null)" \
    "eb-keep-logs rotate: 1 file compressed, 0 runs deleted under ${work}/nolock"

# rotate: one round of short files. One rotate blocks on the real lock
# while the other runs, then finds nothing left to compress.
race="${work}/race"
race_lists="" race_out=""
rm -rf "${race}"
for t in a b; do
    d="${race}/20261001_120000/${t}"
    mkdir -p "${d}"
    for i in 1 2 3 4 5 6; do printf 'line\n' > "${d}/n${i}.log"; done
    for i in 1 2 3; do echo "$(realpath "${d}")/n${i}.log"; done > "${d}/.licensed-logs"
done
"${tool}" rotate "${race}" --compress-after 30 > "${work}/race1" 2>&1 &
r1=$!
"${tool}" rotate "${race}" --compress-after 30 > "${work}/race2" 2>&1 &
r2=$!
wait "${r1}"; s1=$?
wait "${r2}"; s2=$?
for t in a b; do
    d="$(realpath "${race}/20261001_120000/${t}")"
    [ "$(cat "${d}/.licensed-logs")" = "$(printf '%s\n' "${d}/n1.log.gz" "${d}/n2.log.gz" "${d}/n3.log.gz")" ] ||
        race_lists+=" ${t}"
done
race_out="${s1} ${s2} $(cat "${work}/race1" "${work}/race2" | sed 's/ under .*//' | sort | tr '\n' ' ')"
check "two rotations at once: every list whole" "${race_lists}" ""
check "two rotations at once: one rotates, the other then finds nothing" "${race_out}" \
    "0 0 eb-keep-logs rotate: 0 files compressed, 0 runs deleted eb-keep-logs rotate: 12 files compressed, 0 runs deleted "
# Two rotations at once can each list a file by the name it had when they
# read the list; but each list is one of the lists they wrote, whole: every
# line names one of the run's logs, each log once.
race_torn=""
for round in 1 2; do
    rm -rf "${race}"
    for t in a b; do
        d="${race}/20261001_120000/${t}"
        mkdir -p "${d}"
        for i in 1 2 3 4 5 6; do printf 'line\n' > "${d}/n${i}.log"; done
        for i in 1 2 3; do echo "$(realpath "${d}")/n${i}.log"; done > "${d}/.licensed-logs"
    done
    barrier="${work}/barrier-${round}"
    rm -rf "${barrier}"
    mkdir -p "${barrier}"
    EB_KEEP_LOGS_BARRIER="${barrier}" PATH="${work}/nolock-bin:${PATH}" "${tool}" rotate "${race}" --compress-after 30 > /dev/null 2>&1 &
    r1=$!
    EB_KEEP_LOGS_BARRIER="${barrier}" PATH="${work}/nolock-bin:${PATH}" "${tool}" rotate "${race}" --compress-after 30 > /dev/null 2>&1 &
    r2=$!
    wait "${r1}" "${r2}"
    for t in a b; do
        d="$(realpath "${race}/20261001_120000/${t}")"
        [ "$(sed 's/\.gz$//' "${d}/.licensed-logs")" = "$(printf '%s\n' "${d}/n1.log" "${d}/n2.log" "${d}/n3.log")" ] ||
            race_torn+=" round ${round} ${t}"
    done
done
check "two rotations without the lock: every list whole" "${race_torn}" ""

if command -v python3 >/dev/null 2>&1; then
    TOOL_BIN="${tool}" python3 -m unittest "${repo_root}/tests/test_syslog.py" >/dev/null || fails=$((fails + 1))
fi

if [ "${fails}" -ne 0 ]; then echo "${fails} failed"; exit 1; fi
echo "all passed"
