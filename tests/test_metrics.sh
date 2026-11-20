#!/bin/bash
# Exercise the opt-in Prometheus textfile output.
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tool="${TOOL_BIN:-${repo_root}/eb-keep-logs}"
command -v promtool >/dev/null || {
    echo "promtool is required for tests/test_metrics.sh" >&2
    exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/eb-keep-logs-metrics.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
mkdir -p "${work}/bin" "${work}/logs" "${work}/root"
printf 'hello\n' > "${work}/source.log"
cat > "${work}/bin/eb" <<EOF
#!/bin/sh
echo "${work}/source.log"
EOF
chmod +x "${work}/bin/eb"
metrics="${work}/collector/eb-keep-logs.prom"
mkdir -p "${work}/collector"

# The feature is off until explicitly requested.
PATH="${work}/bin:${PATH}" "${tool}" failed 1 First "${work}/logs" >/dev/null
[ ! -e "${metrics}" ]

PATH="${work}/bin:${PATH}" "${tool}" failed --metrics-file "${metrics}" 1 First "${work}/logs" >/dev/null
PATH="${work}/bin:${PATH}" "${tool}" failed 1 Second "${work}/logs" --metrics-file="${metrics}" >/dev/null
promtool check metrics < "${metrics}"
grep -qx 'eb_keep_logs_logs_kept_total 2' "${metrics}"
grep -qx 'eb_keep_logs_bytes_kept_total 12' "${metrics}"
grep -qx 'eb_keep_logs_last_prune_timestamp_seconds 0' "${metrics}"

# Concurrent writers serialize counter updates through the sidecar lock.
writers=()
for n in 1 2 3 4 5 6 7 8; do
    PATH="${work}/bin:${PATH}" "${tool}" failed --metrics-file "${metrics}" 1 "Parallel-${n}" "${work}/logs" >/dev/null &
    writers+=("$!")
done
for writer in "${writers[@]}"; do wait "${writer}"; done
promtool check metrics < "${metrics}"
grep -qx 'eb_keep_logs_logs_kept_total 10' "${metrics}"
grep -qx 'eb_keep_logs_bytes_kept_total 60' "${metrics}"

# Restrictive umasks do not change a new file's documented mode or an
# existing destination's exact mode.
fresh="${work}/collector/fresh.prom"
(umask 077; PATH="${work}/bin:${PATH}" "${tool}" failed --metrics-file "${fresh}" 0 Fresh "${work}/logs" >/dev/null)
[ "$(stat -c %a "${fresh}")" = 644 ]
chmod 640 "${metrics}"
# Hold the sidecar lock across a second boundary. Completion time must be
# chosen after the lock is acquired, not before waiting for it.
metrics_lock="${work}/collector/.eb-keep-logs.prom.lock"
exec {held}>>"${metrics_lock}"
flock -n "${held}"
(umask 077; EB_KEEP_LOGS_NOW=1700000000 "${tool}" rotate "${work}/root" --compress-after 1 --metrics-file "${metrics}" >/dev/null) &
rotator=$!
sleep 2
released=$(date +%s)
flock -u "${held}"
wait "${rotator}"
exec {held}>&-
finished=$(date +%s)
promtool check metrics < "${metrics}"
[ "$(stat -c %a "${metrics}")" = 640 ]
grep -qx 'eb_keep_logs_logs_kept_total 10' "${metrics}"
grep -qx 'eb_keep_logs_bytes_kept_total 60' "${metrics}"
pruned=$(awk '$1 == "eb_keep_logs_last_prune_timestamp_seconds" { print $2 }' "${metrics}")
[ "${pruned}" -ge "${released}" ] && [ "${pruned}" -le "${finished}" ]
[ "${pruned}" -ne 1700000000 ]

# Concurrent rotations of different roots share the metrics lock. A later
# completion already present wins over out-of-order older completions.
future=$((finished + 3600))
sed -i "s/^eb_keep_logs_last_prune_timestamp_seconds .*/eb_keep_logs_last_prune_timestamp_seconds ${future}/" "${metrics}"
mkdir -p "${work}/root-a" "${work}/root-b"
"${tool}" rotate "${work}/root-a" --compress-after 1 --metrics-file "${metrics}" >/dev/null &
rotate_a=$!
"${tool}" rotate "${work}/root-b" --compress-after 1 --metrics-file "${metrics}" >/dev/null &
rotate_b=$!
wait "${rotate_a}" "${rotate_b}"
promtool check metrics < "${metrics}"
grep -qx "eb_keep_logs_last_prune_timestamp_seconds ${future}" "${metrics}"

# The shell implementation must not publish a temporary file when restoring
# its mode fails. The Zig implementation performs the equivalent fchmod
# before rename and its unit tests exercise that path's ordering.
if [ "$(head -c 2 "${tool}")" = '#!' ]; then
    mkdir -p "${work}/no-chmod"
    cat > "${work}/no-chmod/chmod" <<'EOF'
#!/bin/sh
exit 1
EOF
    /bin/chmod +x "${work}/no-chmod/chmod"
    before=$(sha256sum "${metrics}")
    mode_error=$(PATH="${work}/no-chmod:${PATH}" "${tool}" failed --metrics-file "${metrics}" 0 ModeFailure "${work}/logs" 2>&1 >/dev/null)
    case "${mode_error}" in *"cannot set temporary file mode"*) ;; *) exit 1 ;; esac
    [ "$(sha256sum "${metrics}")" = "${before}" ]
    [ "$(find "${work}/collector" -maxdepth 1 -name '*.tmp' -print | wc -l)" -eq 0 ]
fi

# A malformed prior file is preserved instead of resetting the counters.
printf 'eb_keep_logs_logs_kept_total NaN\n' > "${metrics}"
before=$(sha256sum "${metrics}")
PATH="${work}/bin:${PATH}" "${tool}" failed --metrics-file "${metrics}" 0 Third "${work}/logs" >/dev/null 2>&1
[ "$(sha256sum "${metrics}")" = "${before}" ]

# Both implementations accept the full u64 counter range and preserve the
# previous exposition when one more keep would overflow it.
cat > "${metrics}" <<'EOF'
# HELP eb_keep_logs_logs_kept_total Log files kept by eb-keep-logs.
# TYPE eb_keep_logs_logs_kept_total counter
eb_keep_logs_logs_kept_total 18446744073709551614
# HELP eb_keep_logs_bytes_kept_total Bytes written to kept log files by eb-keep-logs.
# TYPE eb_keep_logs_bytes_kept_total counter
eb_keep_logs_bytes_kept_total 18446744073709551609
# HELP eb_keep_logs_last_prune_timestamp_seconds Unix timestamp of the last completed eb-keep-logs rotation.
# TYPE eb_keep_logs_last_prune_timestamp_seconds gauge
eb_keep_logs_last_prune_timestamp_seconds 7
EOF
PATH="${work}/bin:${PATH}" "${tool}" failed --metrics-file "${metrics}" 1 Boundary "${work}/logs" >/dev/null
promtool check metrics < "${metrics}"
grep -qx 'eb_keep_logs_logs_kept_total 18446744073709551615' "${metrics}"
grep -qx 'eb_keep_logs_bytes_kept_total 18446744073709551615' "${metrics}"
before=$(sha256sum "${metrics}")
overflow=$(PATH="${work}/bin:${PATH}" "${tool}" failed --metrics-file "${metrics}" 1 Overflow "${work}/logs" 2>&1 >/dev/null)
case "${overflow}" in *"counter overflow"*|*"Overflow"*) ;; *) exit 1 ;; esac
[ "$(sha256sum "${metrics}")" = "${before}" ]

# A sample may carry Prometheus' optional timestamp, and the name and the
# value may be separated by a tab. The counters add to that value.
{
    printf '%s\n' '# HELP eb_keep_logs_logs_kept_total Log files kept by eb-keep-logs.'
    printf '%s\n' '# TYPE eb_keep_logs_logs_kept_total counter'
    printf '%s\n' 'eb_keep_logs_logs_kept_total 4 1700000000000'
    printf '%s\n' '# HELP eb_keep_logs_bytes_kept_total Bytes written to kept log files by eb-keep-logs.'
    printf '%s\n' '# TYPE eb_keep_logs_bytes_kept_total counter'
    printf 'eb_keep_logs_bytes_kept_total\t20 1700000000001\n'
    printf '%s\n' '# HELP eb_keep_logs_last_prune_timestamp_seconds Unix timestamp of the last completed eb-keep-logs rotation.'
    printf '%s\n' '# TYPE eb_keep_logs_last_prune_timestamp_seconds gauge'
    printf '%s\n' 'eb_keep_logs_last_prune_timestamp_seconds 9 1700000000002'
} > "${metrics}"
PATH="${work}/bin:${PATH}" "${tool}" failed --metrics-file "${metrics}" 1 Timestamped "${work}/logs" >/dev/null || exit 1
promtool check metrics < "${metrics}" || exit 1
grep -qx 'eb_keep_logs_logs_kept_total 5' "${metrics}" || exit 1
grep -qx 'eb_keep_logs_bytes_kept_total 26' "${metrics}" || exit 1
grep -qx 'eb_keep_logs_last_prune_timestamp_seconds 9' "${metrics}" || exit 1

# A dry-run rotation writes no metrics, creates no sidecar lock, and leaves
# an existing exposition untouched even when --metrics-file is given.
dry_root="${work}/dry-root"
mkdir -p "${dry_root}/20261001_120000"
printf 'old\n' > "${dry_root}/20261001_120000/Old.stdout.log"
dry_new="${work}/collector/dry-new.prom"
dry_out=$(EB_KEEP_LOGS_NOW=$(date -d 2026-11-13 +%s) "${tool}" rotate "${dry_root}" --compress-after 5 --dry-run --metrics-file "${dry_new}") || exit 1
case "${dry_out}" in *"eb-keep-logs rotate dry-run: 1 file would be compressed, 0 runs would be deleted under ${dry_root}"*) ;; *) exit 1 ;; esac
[ ! -e "${dry_new}" ] || exit 1
[ ! -e "${work}/collector/.dry-new.prom.lock" ] || exit 1
[ ! -e "${dry_root}/.eb-keep-logs-rotate.lock" ] || exit 1
[ -f "${dry_root}/20261001_120000/Old.stdout.log" ] || exit 1

dry_existing="${work}/collector/dry-existing.prom"
cp "${metrics}" "${dry_existing}"
before=$(sha256sum "${dry_existing}")
EB_KEEP_LOGS_NOW=$(date -d 2026-11-13 +%s) "${tool}" rotate "${dry_root}" --compress-after 5 --dry-run --metrics-file="${dry_existing}" >/dev/null || exit 1
[ "$(sha256sum "${dry_existing}")" = "${before}" ] || exit 1
[ ! -e "${work}/collector/.dry-existing.prom.lock" ] || exit 1
[ ! -e "${dry_root}/.eb-keep-logs-rotate.lock" ] || exit 1

# No temporary output remains after any successful replacement.
[ "$(find "${work}/collector" -maxdepth 1 -name '*.tmp' -print | wc -l)" -eq 0 ]
echo "metrics tests passed"
