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
