#!/bin/bash
# Run the shell implementation (OLD_BIN, default ./eb-keep-logs) and the Zig
# build (TOOL_BIN) on the same invocations and compare exit code, stdout and
# stderr. A difference COMPAT.md lists as deliberate is reported and allowed;
# any other fails the run.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/differential.sh
set -u
repo_root=$(cd "$(dirname "$0")/.." && pwd)
OLD_BIN="${OLD_BIN:-${repo_root}/eb-keep-logs}"
: "${TOOL_BIN:?}"
work=$(mktemp -d "${TMPDIR:-/tmp}/ekl-diff.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
mkdir -p "${work}/logs" "${work}/bin"
printf '#!/bin/bash\nexit 0\n' > "${work}/bin/eb"
chmod +x "${work}/bin/eb"
export PATH="${work}/bin:${PATH}"

diffs=0
# Labels whose difference is deliberate, each with its case in COMPAT.md. A
# difference passes only while COMPAT.md lists that case among the
# deliberate differences.
declare -A deliberate=(
    ["rotate, lock is a symbolic link"]="\`rotate\`'s lock file cannot be opened, or is a symbolic link or not a regular file"
    ["rotate, compress-after overflow"]="\`--compress-after\` or \`--delete-after\` naming more days than an unsigned 64-bit integer holds"
    ["rotate, delete-after overflow"]="\`--compress-after\` or \`--delete-after\` naming more days than an unsigned 64-bit integer holds"
    ["rotate, delete-after past a signed 64-bit integer"]="\`--delete-after\` naming more days than a signed 64-bit integer holds, together with a \`--compress-after\` it is genuinely later than"
    ["rotate, compress-after past a signed 64-bit integer"]="\`--compress-after\` naming more days than a signed 64-bit integer holds, without a \`--delete-after\` of its own"
    ["rotate, EB_KEEP_LOGS_NOW far below a run"]="\`EB_KEEP_LOGS_NOW\` so far below a run's local midnight that the difference overflows a signed 64-bit integer"
    ["rotate, EB_KEEP_LOGS_NOW far above a run"]="\`EB_KEEP_LOGS_NOW\` so far above a run's local midnight that the difference overflows a signed 64-bit integer"
    ["why"]="\`why\`"
    ["history"]="\`history\`"
    ["failures"]="\`failures\`"
    ["loads"]="\`loads\`"
    ["runs"]="\`runs\`"
    ["used"]="\`used\`"
    ["usage"]="\`usage\`"
    ["pending"]="\`pending\`"
    ["lifecycle"]="\`lifecycle\`"
    ["rotate, killed mid-compress"]="a \`rotate\` killed while compressing a file"
)
compat_deliberate=$(sed -n '/^## Deliberate differences$/,/^## /p' "${repo_root}/COMPAT.md")
# The environment both runs get, as env(1) takes it.
run_env=(PATH="${PATH}")
# compare LABEL ARGS...: run both with the same arguments.
compare() {
    local label=$1; shift
    env "${run_env[@]}" "${OLD_BIN}" "$@" > "${work}/o.out" 2> "${work}/o.err"; local oc=$?
    env "${run_env[@]}" "${TOOL_BIN}" "$@" > "${work}/n.out" 2> "${work}/n.err"; local nc=$?
    if [ "${oc}" != "${nc}" ] || ! cmp -s "${work}/o.out" "${work}/n.out" || ! cmp -s "${work}/o.err" "${work}/n.err"; then
        local compat_case="${deliberate[${label}]:-}"
        if [ -n "${compat_case}" ] && grep -qF -- "| ${compat_case} |" <<< "${compat_deliberate}"; then
            echo "deliberate ${label}"
            return
        fi
        # On stderr: zig build test shows a script's stderr, not stdout.
        {
            echo "DIFF ${label}: exit ${oc} vs ${nc}"
            [ -z "${compat_case}" ] || echo "     COMPAT.md lists no deliberate difference: ${compat_case}"
            diff "${work}/o.out" "${work}/n.out" | sed 's/^/     out /'
            diff "${work}/o.err" "${work}/n.err" | sed 's/^/     err /'
        } >&2
        diffs=$((diffs + 1))
    else
        echo "same ${label}"
    fi
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
EB_KEEP_LOGS_NOW="$(date -d 2026-11-13 +%s)" "${OLD_BIN}" rotate "${work}/preview" --compress-after 5 --dry-run > "${work}/dry-parity-old.out" 2> "${work}/dry-parity-old.err"
EB_KEEP_LOGS_NOW="$(date -d 2026-11-13 +%s)" "${TOOL_BIN}" rotate "${work}/preview" --compress-after 5 --dry-run > "${work}/dry-parity-new.out" 2> "${work}/dry-parity-new.err"
if ! cmp -s "${work}/dry-parity-old.out" "${work}/dry-parity-new.out" || ! cmp -s "${work}/dry-parity-old.err" "${work}/dry-parity-new.err"; then
    echo "DIFF rotate, dry-run raw bytes differ between shell and Zig" >&2
    diffs=$((diffs + 1))
fi
dry_count=$(sed -nE 's/^eb-keep-logs rotate dry-run: ([0-9]+) files? would be compressed.*/\1/p' "${work}/dry-parity-old.out")
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
# A kill in the middle of compressing a file leaves behind what each side's
# compression writes mid-way, and a later rotate sees a different run.
mkdir -p "${work}/crash-old/20261001_120000" "${work}/crash-new/20261001_120000"
head -c 20000000 /dev/urandom > "${work}/crash-old/20261001_120000/a.log"
head -c 20000000 /dev/urandom > "${work}/crash-new/20261001_120000/a.log"
"${OLD_BIN}" rotate "${work}/crash-old" --compress-after 5 >/dev/null 2>&1 &
old_pid=$!
gzip_pid=""
for _ in $(seq 1 200); do
    gzip_pid=$(pgrep -f "gzip -9 -- ${work}/crash-old/20261001_120000/a.log" | head -1)
    [ -n "${gzip_pid}" ] && break
    sleep 0.005
done
sleep 0.03
[ -n "${gzip_pid}" ] && kill -KILL "${gzip_pid}" 2>/dev/null
wait "${old_pid}" 2>/dev/null
"${TOOL_BIN}" rotate "${work}/crash-new" --compress-after 5 >/dev/null 2>&1 &
new_pid=$!
sleep 0.05
kill -KILL "${new_pid}" 2>/dev/null
wait "${new_pid}" 2>/dev/null
old_rerun=$("${OLD_BIN}" rotate "${work}/crash-old" --compress-after 5 2>/dev/null)
new_rerun=$("${TOOL_BIN}" rotate "${work}/crash-new" --compress-after 5 2>/dev/null)
old_count=$(sed -nE 's/^eb-keep-logs rotate: ([0-9]+) files? compressed.*/\1/p' <<< "${old_rerun}")
new_count=$(sed -nE 's/^eb-keep-logs rotate: ([0-9]+) files? compressed.*/\1/p' <<< "${new_rerun}")
old_left=no; [ -e "${work}/crash-old/20261001_120000/a.log" ] && old_left=yes
new_left=no; [ -e "${work}/crash-new/20261001_120000/a.log" ] && new_left=yes
label="rotate, killed mid-compress"
if [ "${old_count}" != "${new_count}" ] || [ "${old_left}" != "${new_left}" ]; then
    compat_case="${deliberate[${label}]:-}"
    if [ -n "${compat_case}" ] && grep -qF -- "| ${compat_case} |" <<< "${compat_deliberate}"; then
        echo "deliberate ${label}"
    else
        {
            echo "DIFF ${label}: a second rotate compressed ${old_count} (shell) vs ${new_count} (Zig) file(s), a.log left behind: ${old_left} vs ${new_left}"
            [ -z "${compat_case}" ] || echo "     COMPAT.md lists no deliberate difference: ${compat_case}"
        } >&2
        diffs=$((diffs + 1))
    fi
else
    echo "same ${label}"
fi
# The one run is past --delete-after, and another process writes into it.
mkdir -p "${work}/live/20261001_120000"
echo build > "${work}/live/20261001_120000/B.stdout.log"
(exec 3>>"${work}/live/20261001_120000/B.stdout.log" && : > "${work}/held" && exec sleep 60) &
holder=$!
until [ -e "${work}/held" ]; do sleep 0.05; done
compare "rotate, a run still written into" rotate "${work}/live" --compress-after 5 --delete-after 9
kill "${holder}"; wait "${holder}" 2>/dev/null
compare "why" why --latest --root "${repo_root}/tests/fixtures/build-logs"
compare "history" history hello --root "${repo_root}/tests/fixtures/build-logs"
compare "failures" failures --root "${repo_root}/tests/fixtures/build-logs"
printf 'user=a module=M path=/p host=h time=1\n' > "${work}/loads.log"
compare "loads" loads --module M "${work}/loads.log"
printf '%s\n' '{"userT":{"user":"a","exec_path":"/bin/gmx","syshost":"h","start_time":1}}' > "${work}/runs.json"
compare "runs" runs --exec gmx "${work}/runs.json"
printf '%s\n' '{"userT":{"user":"a","exec_path":"/bin/gmx","syshost":"h","start_time":1}}' > "${work}/used.json"
compare "used" used --prefix /opt "${work}/used.json"
mkdir -p "${work}/software/GROMACS/1.0" "${work}/modules"
compare "usage" usage --software "${work}/software" --modules "${work}/modules" "${work}/used.json"
printf '%s\n' ' * [ ] flex-2.6.4.eb (module: flex/2.6.4)' > "${work}/dry.txt"
compare "pending" pending "${work}/dry.txt"
printf '%s\n' 'min_observation_days = 90' 'warn_after_days = 60' 'forbid_after_days = 180' 'remove_after_days = 365' > "${work}/policy.toml"
"${TOOL_BIN}" usage --software "${work}/software" --modules "${work}/modules" --json "${work}/used.json" > "${work}/usage.json"
compare "lifecycle" lifecycle --policy "${work}/policy.toml" "${work}/usage.json"

echo "${diffs} differences"
[ "${diffs}" -eq 0 ]
