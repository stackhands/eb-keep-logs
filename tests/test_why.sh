#!/bin/bash
# Tests for eb-keep-logs why and history, on the kept logs of real
# EasyBuild 5.4.2 failures in tests/fixtures/build-logs. Both are in the
# Zig build only:
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_why.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac
# Paths in the output are as given, so the expected ones are relative to
# the repository.
cd "${repo_root}" || exit 1
logs=tests/fixtures/build-logs

fails=0
# shellcheck source=tests/lib/check.sh
. "${repo_root}/tests/lib/check.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-why.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

# row LABEL RUN WHAT WHERE ERROR: one row of the why table. The run, what
# failed, the log line, and the error line are checked together.
why_miss=
row() {
    local label=$1 run=$2 what=$3 where=$4 error=$5 out got_what got_where got_error
    out=$("${tool}" why "${logs}/${run}")
    got_what=$(grep -E '^[^ ]+ failed (in|before) ' <<< "${out}")
    got_where=$(sed -n 's/^  log: *//p' <<< "${out}")
    got_error=$(sed -n 's/^    > [0-9]* | //p' <<< "${out}")
    if [ "${got_what}" != "${what}" ] || [ "${got_where}" != "${where}" ] || [ "${got_error}" != "${error}" ]; then
        why_miss="${why_miss}${label}"$'\n'
    fi
}

b=hello-2.12.1-GCCcore-14.2.0
s=sapphirerapids/${b}
# Without a compiler or linker error, the error line is EasyBuild's own.
r=${logs}/20261117_035825
row "wrong checksum" 20261117_035825 \
    "${s} failed in the fetch step, after 48s" \
    "${r}/${s}.failed.ebout.log.gz:61" \
    "== 2026-11-17 03:59:32,778 build_log.py:233 ERROR EasyBuild encountered an error: Checksum verification for /home/alice/sources/h/hello/hello-2.12.1.tar.gz using cf04af86dc085268c5f4470fbae49b18afbc221b78096aab842d934a76bad0ab failed. (at easybuild/framework/easyblock.py:3026 in checksum_step)"
r=${logs}/20261117_040032
row "broken patch" 20261117_040032 \
    "${s} failed in the patch step, after 41s" \
    "${r}/${s}.failed.ebout.log.gz:106" \
    "== 2026-11-17 04:01:16,936 build_log.py:233 ERROR EasyBuild encountered an error: Couldn't apply patch file /home/alice/corpus/cases/patch/hello-2.12.1_env-greeting.patch. Process exited with code 1: patching file src/hello.c"
r=${logs}/20261117_040119
row "missing dependency" 20261117_040119 \
    "${s} failed before its first step" \
    "${r}/${s}.failed.ebout.log.gz:29" \
    "== 2026-11-17 04:01:22,080 build_log.py:233 ERROR EasyBuild encountered an error: Missing dependencies: libgreet/1.0-GCCcore-14.2.0 (no easyconfig file or existing module found) (at easybuild/tools/robot.py:352 in raise_error_missing_deps)"
r=${logs}/20261117_040311
row "failing configure" 20261117_040311 \
    "${s} failed in the configure step, after 2m24s" \
    "${r}/${s}.failed.ebout.log.gz:134" \
    "== 2026-11-17 04:05:39,980 build_log.py:233 ERROR EasyBuild encountered an error: shell command 'configure ...' failed with exit code 77 in configure step for hello-2.12.1-GCCcore-14.2.0.eb (at easybuild/framework/easyblock.py:5266 in run_all_steps)"
r=${logs}/20261117_040928
row "undefined reference" 20261117_040928 \
    "${s} failed in the build step, after 2m30s" \
    "${r}/${s}.failed.ebout.log:295" \
    "hello.c:(.text.startup+0x4a): undefined reference to \`site_greeting'"
r=${logs}/20261117_041222
row "failing sanity check and tests, in one run" 20261117_041222 \
    "sapphirerapids/hello-2.12.1-GCCcore-13.3.0 failed in the sanitycheck step, after 2m54s
${s} failed in the test step, after 2m33s" \
    "${r}/sapphirerapids/hello-2.12.1-GCCcore-13.3.0.failed.ebout.log:258
${r}/${s}.failed.ebout.log:209" \
    "== 2026-11-17 04:17:57,955 build_log.py:233 ERROR EasyBuild encountered an error: Sanity check failed: no file found at 'lib/libhello.a' in /home/alice/eessi/versions/2025.06/software/linux/x86_64/intel/sapphirerapids/software/hello/2.12.1-GCCcore-13.3.0 (at easybuild/framework/easyblock.py:4753 in _sanity_check_step)
== 2026-11-17 04:14:59,217 build_log.py:233 ERROR EasyBuild encountered an error: shell command 'make ...' failed in test step for hello-2.12.1-GCCcore-14.2.0.eb (at easybuild/framework/easyblock.py:2829 in report_test_failure)"
check "why: what failed, where, and the error line" "${why_miss}" ""
check "a run without failures says so" "$("${tool}" why "${logs}/20261117_042207")" \
    "${logs}/20261117_042207: 0 failed builds of 2"

check "the whole text report" "$("${tool}" why "${logs}/20261117_040615")" \
    "$(cat tests/fixtures/why/20261117_040615.txt)"
check "--json: schema 1, on one line" "$("${tool}" why --json "${logs}/20261117_041222")" \
    "$(cat tests/fixtures/why/20261117_041222.json)"

# Which run and which builds.
check "--latest: the newest run" "$("${tool}" why --latest --root "${logs}" | head -1)" \
    "${logs}/20261117_042207: 0 failed builds of 2"
check "no RUN is --latest" "$(cd "${logs}" && "${tool}" why | head -1)" "20261117_042207: 0 failed builds of 2"
check "--latest --target: the newest run with that target" \
    "$("${tool}" why --latest --target generic --root "${logs}" | head -1)" \
    "${logs}/20261117_041222: 0 failed builds of 1"
check "--target: only its builds" \
    "$("${tool}" why --root="${logs}" --target=sapphirerapids 20261117_041222 | head -1)" \
    "${logs}/20261117_041222: 2 failed builds of 2"
# A run read once as kept and once after rotate compressed it reports the
# same, its logs named .gz.
mkdir -p "${work}/rotated"
cp -R "${logs}/20261117_041222" "${work}/rotated/"
plain=$("${tool}" why --json --root "${work}/rotated" 20261117_041222)
plain_history=$("${tool}" history --json --root "${work}/rotated" hello)
EB_KEEP_LOGS_NOW=4102444800 "${tool}" rotate "${work}/rotated" --compress-after 1 > /dev/null
check "rotate compressed every log" "$(find "${work}/rotated" -type f -name '*.log' | wc -l | tr -d ' ')" "0"
check "compressed: the same report" \
    "$("${tool}" why --json --root "${work}/rotated" 20261117_041222 | sed 's/\.log\.gz"/.log"/g')" "${plain}"
check "compressed: the same history" \
    "$("${tool}" history --json --root "${work}/rotated" hello | sed 's/\.log\.gz"/.log"/g')" "${plain_history}"

# A build that kept only its terminal output is read from that; 80-column
# wrapping is undone.
mkdir -p "${work}/stdout/20261117_041222/sapphirerapids"
cp "${logs}/20261117_041222/sapphirerapids/hello-2.12.1-GCCcore-13.3.0.stdout.log" "${work}/stdout/20261117_041222/sapphirerapids/"
out=$("${tool}" why --root "${work}/stdout" 20261117_041222)
check "terminal output only: what failed" "$(grep -E '^[^ ]+ failed ' <<< "${out}")" \
    "sapphirerapids/hello-2.12.1-GCCcore-13.3.0 failed in the sanitycheck step, after 2m54s"
check "terminal output only: EasyBuild's message unwrapped" "$(sed -n 's/^  EasyBuild: *//p' <<< "${out}")" \
    "Sanity check failed: no file found at 'lib/libhello.a' in /home/alice/eessi/versions/2025.06/software/linux/x86_64/intel/sapphirerapids/software/hello/2.12.1-GCCcore-13.3.0"
check "terminal output only: EasyBuild's FAILED entry" "$(sed -n 's/^    > //p' <<< "${out}")" \
    "181 | == FAILED: Installation ended unsuccessfully: Sanity check failed: no file found"

# A run that keeps its builds in its own directory, as failed given the run
# as LOGDIR keeps them, is read as well; they have no target.
mkdir -p "${work}/flat/20261117_040615/easybuild-logs"
cp "${logs}/20261117_040615/sapphirerapids/"* "${work}/flat/20261117_040615/"
out=$("${tool}" why --root "${work}/flat" 20261117_040615)
check "the run's own directory: what failed" "$(grep -E '^[^ ]+ failed ' <<< "${out}")" \
    "${b} failed in the build step, after 3m06s"
check "the run's own directory: where" "$(sed -n 's/^  log: *//p' <<< "${out}")" \
    "${work}/flat/20261117_040615/${b}.failed.ebout.log:291"
check "the run's own directory: no target" \
    "$("${tool}" why --json --root "${work}/flat" 20261117_040615 | grep -o '"target":[^,]*')" '"target":null'

# A log that cannot be read is reported, and the build still listed.
mkdir -p "${work}/broken/20261117_050000/node1"
echo "not gzip" > "${work}/broken/20261117_050000/node1/${b}.failed.ebout.log.gz"
out=$("${tool}" why --root "${work}/broken" 20261117_050000 2> "${work}/err")
check "unreadable log: exit 0" "$?" "0"
check "unreadable log: said on stderr" "$(cat "${work}/err")" \
    "eb-keep-logs: cannot read ${work}/broken/20261117_050000/node1/${b}.failed.ebout.log.gz: BadGzip"
check "unreadable log: the build is listed" "$(sed -n 's/^  log: *//p' <<< "${out}")" \
    "${work}/broken/20261117_050000/node1/${b}.failed.ebout.log.gz (no error recorded)"
# A build whose terminal output records no outcome is counted, not listed.
mkdir -p "${work}/broken/20261117_050000/node2"
echo "== building..." > "${work}/broken/20261117_050000/node2/${b}.stdout.log"
check "no outcome recorded: unknown" \
    "$("${tool}" why --json --root "${work}/broken" 20261117_050000 2> /dev/null | grep -o '"counts":{[^}]*}')" \
    '"counts":{"success":0,"failed":1,"unknown":1}'

# history: every kept build of a package, oldest run first.
check "history: the whole text report" "$("${tool}" history hello --root "${logs}")" \
    "$(cat tests/fixtures/why/history-hello.txt)"
check "history --json: schema 1, on one line" \
    "$("${tool}" history --json --root "${logs}" hello-2.12.1-GCCcore-13.3.0)" \
    "$(cat tests/fixtures/why/history-hello-2.12.1-GCCcore-13.3.0.json)"
check "history: a module name is the easyconfig's" \
    "$("${tool}" history hello/2.12.1-GCCcore-13.3.0 --root "${logs}" | tail -n +2)" \
    "$("${tool}" history hello-2.12.1-GCCcore-13.3.0 --root "${logs}" | tail -n +2)"
check "history: the start of a name only up to a dash" "$("${tool}" history hell --root "${logs}")" \
    "hell: 0 builds under ${logs}"
check "history --target: only its builds" "$("${tool}" history --target=generic --root="${logs}" hello | tail -n 1)" \
    "20261117_041222  generic  success  2m50s     hello-2.12.1-GCCcore-14.2.0"
check "history: ROOT defaults to the current directory" "$(cd "${logs}" && "${tool}" history hello | head -1)" \
    "hello: 11 builds under .: 3 succeeded, 8 failed"
check "history: a build in the run's own directory has no target" \
    "$("${tool}" history hello --root "${work}/flat" | tail -n 1)" \
    "20261117_040615  -       failed   3m06s     ${b}"
check "history: a kept session log alone is a failure, unread" \
    "$("${tool}" history hello --root "${work}/broken" 2>&1)" \
    "hello: 2 builds under ${work}/broken: 0 succeeded, 1 failed, 1 unknown

RUN              TARGET  OUTCOME  DURATION  NAME
20261117_050000  node1   failed   -         ${b}
20261117_050000  node2   unknown  -         ${b}"

# EasyBuild wraps a coloured line in ANSI escapes. The visible line still
# starts with ERROR, and a coloured announcement does not belong in the
# failure message.
late="${work}/colour-late"
mkdir -p "${late}/20261117_060000"
printf '%s\n' '== COMPLETED: Installation ended successfully (took 1 sec)' $'\x1b[31mERROR: late failure\x1b[0m' \
    > "${late}/20261117_060000/hello-2.12.1.stdout.log"
out=$("${tool}" history hello-2.12.1 --root "${late}")
check "coloured error after success" "$(awk 'NR==4 { print $3 }' <<< "${out}")" "failed"
miss="${work}/colour-miss"
mkdir -p "${miss}/20261117_060001"
printf '%s\n' $'\x1b[31mERROR: Missing dependencies: libgreet/1.0\x1b[0m' \
    > "${miss}/20261117_060001/hello-2.12.1.stdout.log"
out=$("${tool}" history hello-2.12.1 --root "${miss}")
check "coloured error alone" "$(awk 'NR==4 { print $3 }' <<< "${out}")" "failed"

# A compressed kept log may end in zero bytes after its last gzip member.
# gzip -d treats those bytes as padding, so history still reads the outcome
# and the duration from the log.
pad="${work}/padded"
mkdir -p "${pad}/20261117_070000"
python3 -c 'import gzip,sys; open(sys.argv[1],"wb").write(gzip.compress(b"== COMPLETED: Installation ended successfully (took 2 secs)\n")+bytes(16))' \
    "${pad}/20261117_070000/hello-2.12.1.stdout.log.gz"
pad_out=$("${tool}" history hello --json --root "${pad}" 2> "${work}/pad.err")
check "history padded gzip: exit 0" "$?" "0"
check "history padded gzip: stderr" "$(cat "${work}/pad.err")" ""
check "history padded gzip: outcome and duration" "$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); b=d["builds"][0]; print(d["counts"]["success"], d["counts"]["unknown"], b["outcome"], b["duration_s"])' <<< "${pad_out}")" "1 0 success 2"
wrap="${work}/colour-wrap"
mkdir -p "${wrap}"
{
    printf '%s\n' '== building...'
    printf '%b\n' '\033[31m== FAILED: Installation ended unsuccessfully: shell command '\''make ...'\'' failed\033[0m'
    printf '%s\n' 'with exit code 2 in build step for hello.eb (took 3 mins 6'
    printf '%s\n' 'secs)'
    printf '%b\n' '\033[1m== Results of the build can be found in the log file(s)\033[0m'
} > "${wrap}/hello-2.12.1.stdout.log"
out=$("${tool}" why "${wrap}")
check "coloured failure: message" "$(sed -n 's/^  EasyBuild:  //p' <<< "${out}")" "shell command 'make ...' failed with exit code 2 in build step for hello.eb"
bare="${work}/colour-bare"
mkdir -p "${bare}"
{
    printf '%s\n' '== building...'
    printf '%b\n' '\033[31m== FAILED: Installation ended unsuccessfully: shell command failed\033[0m'
    printf '%b\n' '\033[1m== Results of the build can be found in the log file(s)\033[0m'
} > "${bare}/hello-2.12.1.stdout.log"
out=$("${tool}" why "${bare}")
check "coloured announcement stays out of the message" "$(sed -n 's/^  EasyBuild:  //p' <<< "${out}")" "shell command failed"

# refused LABEL MESSAGE ARGS...: eb-keep-logs ARGS exits 2 with MESSAGE on
# stderr.
refused() {
    local label=$1 message=$2; shift 2
    "${tool}" "$@" > /dev/null 2> "${work}/err"
    check "refused, ${label}: exit 2" "$?" "2"
    check "refused, ${label}: message" "$(cat "${work}/err")" "eb-keep-logs: ${message}"
}
mkdir -p "${work}/empty"
refused "why, two runs" "why takes one RUN" why a b
refused "why, RUN and --latest" "why takes RUN or --latest, not both" why "${logs}/20261117_040615" --latest
refused "why, unknown option" "unknown option --bogus" why --bogus
refused "why, --target without a value" "--target needs a target" why --target
refused "why, empty --root" "--root needs a directory" why --root=
refused "why, empty RUN" "RUN must not be empty" why ""
refused "why, missing ROOT" "ROOT ${work}/nope is not a directory" why --root "${work}/nope"
refused "why, no run" "no run under ${work}/empty; it holds no directory named YYYYMMDD_HHMMSS. Give --root the directory of the runs, or name one run" why --root "${work}/empty"
refused "why, no run with the target" "no run under ${logs} has a target nope. Give --target a directory of that run" why --latest --target nope --root "${logs}"
refused "why, missing RUN" "RUN ${work}/nope is not a directory" why "${work}/nope"
refused "why, missing TARGET" "TARGET nope is not a directory in ${logs}/20261117_040615" why "${logs}/20261117_040615" --target nope
refused "history, no PACKAGE" "history needs PACKAGE: the easyconfig name without .eb, or NAME/VERSION" history --root "${logs}"
refused "history, two packages" "history takes one PACKAGE" history a b
refused "history, empty PACKAGE" "PACKAGE must not be empty" history ""
refused "history, --latest" "unknown option --latest" history hello --latest
refused "history, --target without a value" "--target needs a target" history hello --target
refused "history, missing ROOT" "ROOT ${work}/nope is not a directory" history hello --root="${work}/nope"
# -h and --help of why and history print what to pass and exit 0.
help_ok() {
    local label=$1; shift
    "${tool}" "$@" > "${work}/help" 2> "${work}/err"
    check "help, ${label}: exit 0" "$?" "0"
    check "help, ${label}: stderr empty" "$(cat "${work}/err")" ""
    check "help, ${label}: names a run directory" "$(grep -c 'YYYYMMDD_HHMMSS' "${work}/help")" "1"
}
help_ok "why --help" why --help
help_ok "why -h" why -h
help_ok "history --help" history --help
help_ok "history -h" history -h

if [ "${fails}" -ne 0 ]; then echo "${fails} failed"; exit 1; fi
echo "all passed"
