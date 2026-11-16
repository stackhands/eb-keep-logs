#!/bin/bash
# Tests for eb-keep-logs with a stub eb. Run from the repository root:
#   bash tests/test_eb_keep_logs.sh
#   TOOL_BIN=/path/to/eb-keep-logs bash tests/test_eb_keep_logs.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
# TOOL_BIN runs the suite against another build of the tool.
tool="${TOOL_BIN:-${repo_root}/eb-keep-logs}"

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
if [ "\${EASYBUILD_OUTPUT_STYLE:-auto}" = basic ]; then
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

# failed: an EasyBuild without output styles refuses EASYBUILD_OUTPUT_STYLE
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
if [ -n "\${EASYBUILD_OUTPUT_STYLE+set}" ]; then
    echo "ERROR: Failed to parse configuration options: EASYBUILD_OUTPUT_STYLE" >&2
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

# failed: bad arguments are refused with exit 2
"${tool}" failed x Foo "${work}/logs" 2>/dev/null
check "non-numeric status refused" "$?" "2"
"${tool}" failed 1 Foo "${work}/nope" 2>/dev/null
check "missing logdir refused" "$?" "2"

# rotate: runs named by date; 'now' is fixed at 2026-11-13
root="${work}/root"
mkdir -p "${root}/20261001_120000/snel-zen4" "${root}/20261110_120000" "${root}/20260801_090000" "${root}/notarun"
echo old > "${root}/20261001_120000/snel-zen4/A.stdout.log"
echo secret > "${root}/20261001_120000/snel-zen4/B.failed.ebout.log"
chmod 640 "${root}/20261001_120000/snel-zen4/B.failed.ebout.log"
realpath "${root}/20261001_120000/snel-zen4/B.failed.ebout.log" > "${root}/20261001_120000/snel-zen4/.licensed-logs"
echo recent > "${root}/20261110_120000/C.stdout.log"
echo ancient > "${root}/20260801_090000/D.stdout.log"
echo other > "${root}/notarun/E.log"
EB_KEEP_LOGS_NOW=$(date -d 2026-11-13 +%s)
export EB_KEEP_LOGS_NOW

"${tool}" rotate "${root}" --compress-after 30 >/dev/null
check "old run compressed" "$(ls "${root}/20261001_120000/snel-zen4" | sort | tr '\n' ' ')" "A.stdout.log.gz B.failed.ebout.log.gz "
check "compressed content intact" "$(zcat "${root}/20261001_120000/snel-zen4/A.stdout.log.gz")" "old"
check "closed log stays closed" "$(stat -c '%A' "${root}/20261001_120000/snel-zen4/B.failed.ebout.log.gz" | cut -c8-10)" "---"
check ".licensed-logs follows" "$(cat "${root}/20261001_120000/snel-zen4/.licensed-logs")" "$(realpath "${root}/20261001_120000/snel-zen4")/B.failed.ebout.log.gz"
check "recent run untouched" "$(ls "${root}/20261110_120000")" "C.stdout.log"
check "non-run directory untouched" "$(ls "${root}/notarun")" "E.log"
check "no deletion without --delete-after" "$(ls -d "${root}/20260801_090000" 2>/dev/null | wc -l | tr -d ' ')" "1"

"${tool}" rotate "${root}" --compress-after 30 --delete-after 90 >/dev/null
check "run past --delete-after deleted" "$(ls -d "${root}/20260801_090000" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "run inside --delete-after kept" "$(ls -d "${root}/20261001_120000" 2>/dev/null | wc -l | tr -d ' ')" "1"

"${tool}" rotate "${root}" --compress-after 30 --delete-after 10 2>/dev/null
check "delete before compress refused" "$?" "2"
"${tool}" rotate "${root}" 2>/dev/null
check "rotate without --compress-after refused" "$?" "2"

if [ "${fails}" -ne 0 ]; then echo "${fails} failed"; exit 1; fi
echo "all passed"
