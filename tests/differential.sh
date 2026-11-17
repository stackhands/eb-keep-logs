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
compare "rotate, delete not later" rotate "${work}/logs" --compress-after 5 --delete-after 5
compare "rotate, empty delete" rotate "${work}/logs" --compress-after 5 --delete-after ""
compare "rotate, nothing to do" rotate "${work}/logs" --compress-after 5 --delete-after 9
EB_KEEP_LOGS_NOW='' compare "rotate, empty EB_KEEP_LOGS_NOW" rotate "${work}/logs" --compress-after 5
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
