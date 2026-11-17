# Compatibility of the Zig build with the shell script

The Zig build (0.2.x) keeps the shell script's (0.1.0) interface. The shell
script stays in the repository as the reference: `tests/test_eb_keep_logs.sh`
runs against either through `TOOL_BIN`, and `tests/differential.sh` runs both
on the same invocations.

## Kept

| | |
|---|---|
| commands | `failed STATUS NAME LOGDIR [TMP_LOGDIR]`, `rotate ROOT --compress-after DAYS [--delete-after DAYS]`, `-h`, `--help`, `--version` |
| exit codes | 0 on success and on every `failed` that got past its arguments; 2 for a refused invocation, after `eb-keep-logs: MESSAGE` on stderr; 2 with the usage text on stdout for no arguments |
| environment | `PATH` (finds `eb`), `EASYBUILD_TMPDIR`, `EB_KEEP_LOGS_NOW`, `EB_PIPELINE_LOG_DIR`, `TZ`, `TZDIR` |
| `eb` | `eb --last-log [--tmp-logdir=TMP_LOGDIR] --output-style=basic`, and the same without `--output-style` when that fails or prints nothing; the last line printed is the log |
| stdout | `Failed build log: LOGDIR/NAME.failed.ebout.log`, `Failed command output: LOGDIR/NAME.failed.command-{out,err}.txt`, `Failed meson test log: LOGDIR/NAME.failed.meson-testlog.txt`, `Failed command output not kept: EASYBUILD_TMPDIR is not set.`, `Failed command output not kept: PATH is not under EASYBUILD_TMPDIR.`, `Failed command output not kept: PATH belongs to another user.`, `No EasyBuild log to keep for NAME.`, `No EasyBuild log to keep for NAME: eb is not on PATH.`, `No EasyBuild log to keep for NAME: eb --last-log exited N.`, `No EasyBuild log to keep for NAME: PATH is another build's log.`, `eb-keep-logs rotate: N files compressed, M runs deleted under ROOT`, with `1 file` and `1 run` for a count of one; LOGDIR in these lines without its trailing slashes |
| files | kept files closed to others (command streams mode 0600), their resolved paths appended to `LOGDIR/.licensed-logs` unless already listed; on a failure, `NAME.stdout.log`, a TMP_LOGDIR below LOGDIR and the regular files directly in it closed to others, a symbolic link left as it is; `rotate` writes `FILE.gz` with the file's mode and updates `.licensed-logs` to the `.gz` path |
| run ages | days from the local midnight of the date in the run's name, as `date -d YYYYMMDD` computes it, including TZ rules, except for the zones under unintended differences; a run whose local midnight does not exist is skipped |
| the run in progress | `rotate` neither compresses nor deletes the run that holds its stdout or stderr, when either is a regular file, or `EB_PIPELINE_LOG_DIR` |

## Deliberate differences

| case | shell script | Zig build |
|---|---|---|
| no arguments, `--help` | prints a trailing half sentence from the script's header | stops after the `--version` line |
| `--version` | `eb-keep-logs 0.1.0` | `eb-keep-logs 0.2.1 (TARGET, MODE, zig VERSION, COMMIT)`; the first two words are unchanged |
| `--compress-after` or `--delete-after` with no value after it | never returns | refused, exit 2 |
| `EB_KEEP_LOGS_NOW` not empty and not an integer | evaluated as shell arithmetic | refused, exit 2 |
| a copy into LOGDIR fails | error from cp, then the file is still listed and reported | error on stderr; the file is neither listed nor reported |
| a copy into an existing LOGDIR file fails part way (a full disk) | cp truncates the file first, so the previous bytes are gone | the previous file is left unchanged; nothing is listed or reported |
| a symbolic link or non-regular file at a destination name in LOGDIR | cp writes through it | refused, reported on stderr |
| `NAME.stdout.log` or TMP_LOGDIR that cannot be closed to others | chmod's error on stderr | `eb-keep-logs: cannot close PATH to others: ERROR` on stderr |
| the failing command's streams | checked by path (`realpath`, `-L`, `stat`), then copied | opened without following a symbolic link at the last component; the same checks run on the open file, and that file is copied |
| `.licensed-logs` after `rotate` | rewritten by every compressed file, as a new file owned by the caller | rewritten once per run when a line changes, keeping its owner (when permitted), mode and access ACL (access control list) entries, replaced atomically |
| a run directory that cannot be removed | counted as deleted | reported on stderr, not counted |
| compression | runs `gzip -9`, `find` and `awk` | in process; the gzip header (name, mtime, flags, OS) matches `gzip -9`, the compressed bytes differ; a file with other hard links or an existing `.gz` is skipped as gzip skips it |
| `eb --last-log` that does not return | waits without a limit | its process group is killed after 300 s, and nothing is kept |
| a log larger than 1 GiB | scanned | copied, not checked for another build and not scanned for the command output or meson paths, with a message on stderr |
| a meson testlog larger than 1 GiB | kept unless its summary shows every test passing | kept without reading the summary, with a message on stderr |
| a log with NUL bytes | `grep` reports a binary match and the scan finds nothing | scanned as text |
| `date` not GNU's, as on Ubuntu from 25.10, where `date` is uutils' and GNU's is `gnudate` | run ages follow that `date`; uutils' 0.10.0 reads as UTC some `TZ` rule strings that glibc reads, such as one after a `:` or one without an end rule: `TZ=CET-1CEST,M3.5.0 date -d 20261101 +%s` prints 1793491200 | run ages as GNU `date` gives them, whatever `date` is: 1793484000, as `gnudate` prints |

## Unintended differences

The Zig build does not mean to differ from the shell script in these cases,
each shown by a command. Any other difference from the shell script that is
not listed above is a bug in the Zig build.

| case | shell script | Zig build |
|---|---|---|
| `TZ` a rule string with daylight saving time but no rules, such as `NZST-12NZDT`, where `TZDIR` holds a `posixrules` file | glibc takes the changes from that file's transitions (New York's on most systems), moved by the difference between its offsets and the string's, and after the last of them uses the file's own rule and offsets: `TZ=NZST-12NZDT date -d 20260309 +%s` prints 1772971200, in standard time | the second Sunday in March to the first Sunday in November, at 02:00, in every year, as glibc has it without `posixrules`: 1772967600, in daylight time |
| `TZ` a rule string with an `Mm.w.d` rule whose month is not 1 to 12, or not given, such as `CET-1CEST,M13.1.0,M10.5.0/3` | glibc reads days from outside its table of months, which C leaves undefined: `TZ=CET-1CEST,M13.1.0,M10.5.0/3 date -d 20260701 +%s` prints 1782860400 | the rule falls on 1 January: 1782856800 |
| a zone file with leap seconds, as the `right/` zones and `zic -L` have | glibc counts them, 27 by 2026: `TZ=right/UTC date -d 20261101 +%s` prints 1793491227 | leap seconds are not counted: 1793491200 |
| a zone file whose first time type is daylight saving time, that has no transitions and a footer whose offsets are not those of its first standard time type, or whose footer glibc cannot read; no file of tzdata's is one, but `zic` writes the first kind for a zone that starts in daylight saving time | glibc uses the first standard time type before the first transition and when there are none, and UTC after the last transition when it cannot read the footer: `printf 'Zone X 1:00 1:00 CEST 2000\n\t1:00 - CET\n' > /tmp/x.zi && zic -d /tmp/z /tmp/x.zi && TZ=/tmp/z/X date -d 19990701 +%s` prints 930783600, in standard time | the first time type before the first transition, and the footer when there are no transitions, as RFC 8536 has it; after the last transition, its offset when the footer cannot be read: 930780000, in daylight time |
