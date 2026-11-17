#!/bin/bash
# One build run of the corpus, laid out as eb-pipeline lays out a run:
# ROOT/STAMP/TARGET/, each easyconfig's output in STEM.stdout.log, its
# --tmp-logdir in easybuild-logs/STEM, and eb-keep-logs failed after a failed
# line, with its output in STEM.keep-logs.log. EasyBuild comes from EESSI
# 2025.06 with EESSI-extend, which installs on top of EESSI.
#
# Usage: [ROOT=DIR] [STAMP=YYYYMMDD_HHMMSS] run.sh TARGET CASE...
#   CASE     a directory under cases/ holding one easyconfig.
#   ROOT     the log tree; default ~/build-logs.
#   STAMP    puts another target into a run that is already there.
#   TARGET   generic builds for EESSI's x86_64/generic; any other name
#            builds for the CPU EESSI detects.
set -uo pipefail
target=$1
shift
cases=$(cd "$(dirname "$0")/cases" && pwd)
root=${ROOT:-$HOME/build-logs}
stamp=${STAMP:-$(date +%Y%m%d_%H%M%S)}
logdir=$root/$stamp/$target
mkdir -p "$logdir"
if [ "$target" = generic ]; then
    export EESSI_SOFTWARE_SUBDIR_OVERRIDE=x86_64/generic
fi
# EESSI's init and Lmod read unset variables.
set +u
# shellcheck disable=SC1091
source /cvmfs/software.eessi.io/versions/2025.06/init/bash >/dev/null 2>&1
module load EESSI-extend/2025.06-easybuild >/dev/null 2>&1
set -u
export EASYBUILD_TMPDIR=/tmp/$USER/easybuild EASYBUILD_SOURCEPATH=$HOME/sources
for case in "$@"; do
    ec=$(echo "$cases/$case/"*.eb)
    stem=$(basename "$ec" .eb)
    eb "$ec" --robot --tmp-logdir="$logdir/easybuild-logs/$stem" > "$logdir/$stem.stdout.log" 2>&1
    status=$?
    echo "$stamp/$target $case: eb exited $status"
    if [ "$status" -ne 0 ]; then
        EASYBUILD_OUTPUT_STYLE=basic eb-keep-logs failed "$status" "$stem" "$logdir" \
            "$logdir/easybuild-logs/$stem" > "$logdir/$stem.keep-logs.log" 2>&1
    fi
done
