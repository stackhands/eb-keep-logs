#!/bin/bash
# Make the fixture tree from a log tree that run.sh wrote, by dropping lines
# and never editing one: each kept session log goes through trim-log.awk, a
# kept command output longer than 160 lines keeps its first 10 and last 150,
# and EasyBuild's own logs in easybuild-logs/ stay out (the kept session log
# is a copy of one). The runs whose files rotate had compressed are
# compressed again, by EB_KEEP_LOGS rotate.
#
# Usage: make-fixtures.sh SRC_ROOT DEST_ROOT EB_KEEP_LOGS
set -euo pipefail
[ $# -eq 3 ] || { echo "usage: make-fixtures.sh SRC_ROOT DEST_ROOT EB_KEEP_LOGS" >&2; exit 2; }
src=$1
dest=$2
tool=$3
here=$(cd "$(dirname "$0")" && pwd)

copy_run() {
    local run=$1 target f base out
    for target in "$src/$run"/*/; do
        target=${target%/}
        target=${target##*/}
        mkdir -p "$dest/$run/$target"
        for f in "$src/$run/$target"/* "$src/$run/$target/.licensed-logs"; do
            [ -f "$f" ] || continue
            base=${f##*/}
            base=${base%.gz}
            out=$dest/$run/$target/$base
            case "$base" in
                *.failed.ebout.log) zcat -f -- "$f" | awk -f "$here/trim-log.awk" > "$out" ;;
                *.failed.command-*.txt)
                    zcat -f -- "$f" | awk '{ l[NR] = $0 }
                        END { for (i = 1; i <= NR; i++) if (NR <= 160 || i <= 10 || i > NR - 150) print l[i] }' > "$out" ;;
                *) zcat -f -- "$f" > "$out" ;;
            esac
        done
    done
}

rm -rf -- "$dest"
mkdir -p -- "$dest"
compressed=()
plain=()
for run in "$src"/*/; do
    run=${run%/}
    run=${run##*/}
    if find "$src/$run" -name '*.gz' -print -quit | grep -q .; then
        compressed+=("$run")
    else
        plain+=("$run")
    fi
done
for run in "${compressed[@]}"; do copy_run "$run"; done
if [ ${#compressed[@]} -gt 0 ]; then
    # Now is the day after the newest compressed run, so rotate takes each
    # of them and nothing else is in the tree yet.
    newest=${compressed[-1]}
    now=$(($(date -u -d "${newest:0:4}-${newest:4:2}-${newest:6:2} 12:00" +%s) + 86400))
    TZ=UTC EB_KEEP_LOGS_NOW=$now "$tool" rotate "$dest" --compress-after 1
    rm -f -- "$dest/.eb-keep-logs-rotate.lock"
fi
for run in "${plain[@]}"; do copy_run "$run"; done
