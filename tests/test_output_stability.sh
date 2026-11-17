#!/bin/bash
# Assert existing default command outputs stay byte-identical after opt-in additions.
#   TOOL_BIN=zig-out/bin/eb-keep-logs bash tests/test_output_stability.sh
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tool="${TOOL_BIN:?TOOL_BIN names the Zig build}"
case "${tool}" in /*) ;; *) tool="${PWD}/${tool}" ;; esac
old_bin="${repo_root}/eb-keep-logs"

fails=0
check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        {
            echo "FAIL $1"
            echo "expected: $3"
            echo "got:      $2"
        } >&2
        fails=$((fails + 1))
    fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-stability.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
mkdir -p "${work}/logs" "${work}/empty"

expect() {
    local label=$1 expected_status=$2 expected_out=$3 expected_err=$4
    shift 4
    "$@" > "${work}/out" 2> "${work}/err"
    status=$?
    if [ "${status}" -ne "${expected_status}" ]; then
        echo "FAIL ${label}: status ${status} != ${expected_status}" >&2
        fails=$((fails + 1))
        return 1
    fi
    printf '%s' "${expected_out}" > "${work}/exp.out"
    printf '%s' "${expected_err}" > "${work}/exp.err"
    if ! /usr/bin/cmp -s "${work}/exp.out" "${work}/out"; then
        echo "FAIL ${label}: stdout differs" >&2
        /usr/bin/diff -u "${work}/exp.out" "${work}/out" >&2 || true
        fails=$((fails + 1))
        return 1
    fi
    if ! /usr/bin/cmp -s "${work}/exp.err" "${work}/err"; then
        echo "FAIL ${label}: stderr differs" >&2
        /usr/bin/diff -u "${work}/exp.err" "${work}/err" >&2 || true
        fails=$((fails + 1))
        return 1
    fi
    echo "ok   ${label}"
}

(
    cd "${work}" || exit 1
    expect "failed status 0 no-op" 0 "" "" "${tool}" failed 0 Foo logs
    expect "rotate empty tree" 0 "eb-keep-logs rotate: 0 files compressed, 0 runs deleted under logs
" "" "${tool}" rotate logs --compress-after 5 --delete-after 9
    PATH="${work}/empty" expect "failed no eb on PATH" 0 "No EasyBuild log to keep for Foo: eb is not on PATH.
" "" "${tool}" failed 3 Foo logs
)

# failed and rotate match the reference shell implementation byte-for-byte.
mkdir -p "${work}/bin" "${work}/logs-o" "${work}/logs-n"
printf '== processing EasyBuild easyconfig /ec/Foo-1.0.eb\nerror: bad\n' > "${work}/eb.log"
cat > "${work}/bin/eb" <<EOF
#!/bin/bash
echo "${work}/eb.log"
EOF
chmod +x "${work}/bin/eb"

PATH="${work}/bin:${PATH}" "${old_bin}" failed 1 Foo-1.0 "${work}/logs-o" > "${work}/failed-o.out" 2> "${work}/failed-o.err"
PATH="${work}/bin:${PATH}" "${tool}" failed 1 Foo-1.0 "${work}/logs-n" > "${work}/failed-n.out" 2> "${work}/failed-n.err"
sed "s|${work}/logs-o|LOGDIR|g" "${work}/failed-o.out" > "${work}/failed-o.norm"
sed "s|${work}/logs-n|LOGDIR|g" "${work}/failed-n.out" > "${work}/failed-n.norm"
check "failed stdout byte-identical" "$(cmp -s "${work}/failed-o.norm" "${work}/failed-n.norm" && echo ok)" "ok"
check "failed stderr byte-identical" "$(cmp -s "${work}/failed-o.err" "${work}/failed-n.err" && echo ok)" "ok"
check "failed kept log byte-identical" "$(cmp -s "${work}/logs-o/Foo-1.0.failed.ebout.log" "${work}/logs-n/Foo-1.0.failed.ebout.log" && echo ok)" "ok"

mkdir -p "${work}/rot-o/20261001_120000" "${work}/rot-n/20261001_120000"
printf 'log line\n' > "${work}/rot-o/20261001_120000/a.log"
printf 'log line\n' > "${work}/rot-n/20261001_120000/a.log"
EB_KEEP_LOGS_NOW=1794873600 "${old_bin}" rotate "${work}/rot-o" --compress-after 5 > "${work}/rot-o.out" 2> "${work}/rot-o.err"
EB_KEEP_LOGS_NOW=1794873600 "${tool}" rotate "${work}/rot-n" --compress-after 5 > "${work}/rot-n.out" 2> "${work}/rot-n.err"
sed "s|${work}/rot-o|ROOT|g" "${work}/rot-o.out" > "${work}/rot-o.norm"
sed "s|${work}/rot-n|ROOT|g" "${work}/rot-n.out" > "${work}/rot-n.norm"
check "rotate stdout byte-identical" "$(cmp -s "${work}/rot-o.norm" "${work}/rot-n.norm" && echo ok)" "ok"
check "rotate stderr byte-identical" "$(cmp -s "${work}/rot-o.err" "${work}/rot-n.err" && echo ok)" "ok"

# Zig-only subcommands produce exact unchanged outputs.
why_out=$(cd "${repo_root}" && "${tool}" why --root tests/fixtures/build-logs 20261117_041222)
check "why default output unchanged" "$(printf '%s\n' "${why_out}" | head -n 7)" $'tests/fixtures/build-logs/20261117_041222: 2 failed builds of 3\n\nsapphirerapids/hello-2.12.1-GCCcore-13.3.0 failed in the sanitycheck step, after 2m54s\n  package:    hello/2.12.1-GCCcore-13.3.0\n  easyconfig: /home/alice/corpus/cases/sanity/hello-2.12.1-GCCcore-13.3.0.eb\n  EasyBuild:  Sanity check failed: no file found at '\''lib/libhello.a'\'' in /home/alice/eessi/versions/2025.06/software/linux/x86_64/intel/sapphirerapids/software/hello/2.12.1-GCCcore-13.3.0
  log:        tests/fixtures/build-logs/20261117_041222/sapphirerapids/hello-2.12.1-GCCcore-13.3.0.failed.ebout.log:258'

hist_out=$(cd "${repo_root}" && "${tool}" history --root tests/fixtures/build-logs hello)
check "history default output unchanged" "${hist_out}" $'hello: 11 builds under tests/fixtures/build-logs: 3 succeeded, 8 failed\n\nRUN              TARGET          OUTCOME  DURATION  NAME\n20261117_035825  sapphirerapids  failed   48s       hello-2.12.1-GCCcore-14.2.0\n20261117_040032  sapphirerapids  failed   41s       hello-2.12.1-GCCcore-14.2.0\n20261117_040119  sapphirerapids  failed   -         hello-2.12.1-GCCcore-14.2.0\n20261117_040311  sapphirerapids  failed   2m24s     hello-2.12.1-GCCcore-14.2.0\n20261117_040615  sapphirerapids  failed   3m06s     hello-2.12.1-GCCcore-14.2.0\n20261117_040928  sapphirerapids  failed   2m30s     hello-2.12.1-GCCcore-14.2.0\n20261117_041222  generic         success  2m50s     hello-2.12.1-GCCcore-14.2.0\n20261117_041222  sapphirerapids  failed   2m54s     hello-2.12.1-GCCcore-13.3.0\n20261117_041222  sapphirerapids  failed   2m33s     hello-2.12.1-GCCcore-14.2.0\n20261117_042207  sapphirerapids  success  2m40s     hello-2.12.1-GCCcore-13.3.0\n20261117_042207  sapphirerapids  success  2m52s     hello-2.12.1-GCCcore-14.2.0'

printf 'user=alice module=GROMACS/2024.1 path=/cvmfs/g.lua host=login01 time=1\n' > "${work}/loads.log"
check "loads default output unchanged" "$("${tool}" loads --module GROMACS/2024.1 "${work}/loads.log")" \
    "user=alice host=login01 time=1 path=/cvmfs/g.lua"

printf '%s\n' '{"userT":{"user":"ada","exec_path":"/opt/site/bin/gmx","syshost":"login01","start_time":"1428767000"}}' > "${work}/runs.json"
check "runs default output unchanged" "$("${tool}" runs --exec gmx "${work}/runs.json")" \
    "user=ada host=login01 time=1428767000 path=/opt/site/bin/gmx"

mkdir -p "${work}/soft/Foo/1.0" "${work}/mods/Foo"
touch "${work}/mods/Foo/1.0.lua"
printf '%s\n' "{\"userT\":{\"user\":\"u\",\"exec_path\":\"${work}/soft/Foo/1.0/bin/foo\",\"start_time\":\"200\"}}" > "${work}/used.json"
check "used default output unchanged" "$("${tool}" used --prefix "${work}/soft/Foo/1.0" "${work}/used.json")" \
    "path=${work}/soft/Foo/1.0/bin/foo kind=run last=200 count=1"

check "usage default output unchanged" "$("${tool}" usage --software "${work}/soft" --modules "${work}/mods" "${work}/used.json")" \
    "active Foo/1.0 hits=1 last=200"

printf ' * [ ] $CFGS/f/flex/flex-2.6.4.eb (module: flex/2.6.4)\n' > "${work}/dry.txt"
check "pending default output unchanged" "$("${tool}" pending "${work}/dry.txt")" \
    "build flex/2.6.4"

echo "${fails} failed"
[ "${fails}" -eq 0 ]
