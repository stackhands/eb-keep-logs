# Compatibility of the Zig build with the shell script

The Zig build (0.2.x) keeps the shell script's (0.1.0) interface. The shell
script stays in the repository as the reference: `tests/test_eb_keep_logs.sh`
runs against either through `TOOL_BIN`, and `tests/differential.sh` runs both
on the same invocations.

## Kept

| | |
|---|---|
| commands | `failed STATUS NAME LOGDIR [TMP_LOGDIR]`, `rotate ROOT --compress-after DAYS [--delete-after DAYS] [--lock-timeout SECONDS]`, `-h`, `--help`, `--version` |
| usage | the same text on stdout for `-h`, `--help` and no arguments |
| exit codes | 0 on success and on every `failed` that got past its arguments; 2 for a refused invocation, after `eb-keep-logs: MESSAGE` on stderr; 2 with the usage text on stdout for no arguments; 75 when another `rotate` holds ROOT's lock past `--lock-timeout`, after `eb-keep-logs: another rotate holds the lock ROOT/.eb-keep-logs-rotate.lock; gave up after N s (--lock-timeout)` on stderr |
| one rotate at a time | `rotate` holds an exclusive flock(2) on `ROOT/.eb-keep-logs-rotate.lock`, created when missing, from before it reads ROOT until it exits; it waits up to `--lock-timeout` seconds for it, 600 without the option or with an empty value, 0 not at all, 999999999 at most; it opens the file for reading when it may not write it; a lock file that cannot be opened, or a symbolic link or non-regular file at its name, is refused, exit 2; on a file system that cannot lock, `rotate` says so on stderr and rotates without the lock |
| environment | `PATH` (finds `eb`), `EASYBUILD_TMPDIR`, `EB_KEEP_LOGS_NOW`, `EB_PIPELINE_LOG_DIR`, `TZ`, `TZDIR` |
| `eb` | `eb --last-log [--tmp-logdir=TMP_LOGDIR] --output-style=basic`, and the same without `--output-style` when that fails or prints nothing; the last line printed is the log |
| stdout | `Failed build log: LOGDIR/NAME.failed.ebout.log`, `Failed command output: LOGDIR/NAME.failed.command-{out,err}.txt`, `Failed meson test log: LOGDIR/NAME.failed.meson-testlog.txt`, `Failed command output not kept: EASYBUILD_TMPDIR is not set.`, `Failed command output not kept: PATH is not under EASYBUILD_TMPDIR.`, `Failed command output not kept: PATH belongs to another user.`, `No EasyBuild log to keep for NAME.`, `No EasyBuild log to keep for NAME: eb is not on PATH.`, `No EasyBuild log to keep for NAME: eb --last-log exited N.`, `No EasyBuild log to keep for NAME: PATH is another build's log.`, `eb-keep-logs rotate: N files compressed, M runs deleted under ROOT`, with `1 file` and `1 run` for a count of one; LOGDIR in these lines without its trailing slashes |
| files | kept files closed to others (command streams mode 0600), their resolved paths appended to `LOGDIR/.licensed-logs` unless already listed; on a failure, `NAME.stdout.log`, a TMP_LOGDIR below LOGDIR and the regular files directly in it closed to others, a symbolic link left as it is; `rotate` writes `FILE.gz` with the file's mode and updates `.licensed-logs` to the `.gz` path, writing the new list to a file of its own beside the old one and renaming it over the list, so the list is always one whole version |
| run ages | days from the local midnight of the date in the run's name, as `date -d YYYYMMDD` computes it, including TZ rules, except for the zones under unintended differences; a run whose local midnight does not exist is skipped |
| the run in progress | `rotate` neither compresses nor deletes the run that holds its stdout or stderr, when either is a regular file, or `EB_PIPELINE_LOG_DIR` |
| runs still written into | after taking its lock, `rotate` reads the links `/proc/PID/fd/N` of every process whose descriptors it may read; a run that holds the path a link with its owner's write bit names, also when the path ends in ` (deleted)`, is neither compressed nor deleted; without `/proc`, no run is left alone for this |

## Deliberate differences

| case | shell script | Zig build |
|---|---|---|
| `--version` | `eb-keep-logs 0.1.0` | `eb-keep-logs 0.2.1 (TARGET, MODE, zig VERSION, COMMIT)`; the first two words are unchanged |
| `why` | refused with `eb-keep-logs: why is in the Zig build only`, exit 2 | says why the run's builds failed, from their kept logs, read through gzip when rotated |
| `history` | refused with `eb-keep-logs: history is in the Zig build only`, exit 2 | lists how each kept build of a package went, run by run |
| `loads` | refused with `eb-keep-logs: loads is in the Zig build only`, exit 2 | prints who loaded a module, from Lmod's ModuleUsageTracking lines |
| `runs` | refused with `eb-keep-logs: runs is in the Zig build only`, exit 2 | prints who ran an executable, from XALT run records |
| `used` | refused with `eb-keep-logs: used is in the Zig build only`, exit 2 | lists paths under a prefix in XALT and Lmod records |
| `pending` | refused with `eb-keep-logs: pending is in the Zig build only`, exit 2 | prints what a dry-run or missing-modules report still has to build |
| `--compress-after` or `--delete-after` with no value after it | never returns | refused, exit 2 |
| `EB_KEEP_LOGS_NOW` not empty and not an integer | evaluated as shell arithmetic | refused, exit 2 |
| `rotate`'s lock file cannot be opened, or is a symbolic link or not a regular file | `eb-keep-logs: cannot lock PATH`, exit 2, from a look at the name just before it is opened | `eb-keep-logs: cannot lock PATH: ERROR`, exit 2, from the open itself |
| the file system cannot lock `rotate`'s lock file | flock(1)'s error, then `eb-keep-logs: cannot lock PATH; rotating without the lock`; also when flock(1) is missing | `eb-keep-logs: cannot lock PATH: ERROR; rotating without the lock` |
| a `rotate` waiting for the lock | takes it as soon as it is let go, as flock(1) blocks | tries for it every 20 ms |
| a copy into LOGDIR fails | error from cp, then the file is still listed and reported | error on stderr; the file is neither listed nor reported |
| a copy into an existing LOGDIR file fails part way (a full disk) | cp truncates the file first, so the previous bytes are gone | the previous file is left unchanged; nothing is listed or reported |
| a symbolic link or non-regular file at a destination name in LOGDIR | cp writes through it | refused, reported on stderr |
| `NAME.stdout.log` or TMP_LOGDIR that cannot be closed to others | chmod's error on stderr | `eb-keep-logs: cannot close PATH to others: ERROR` on stderr |
| the failing command's streams | checked by path (`realpath`, `-L`, `stat`), then copied | opened without following a symbolic link at the last component; the same checks run on the open file, and that file is copied |
| `.licensed-logs` after `rotate` | rewritten by every compressed file, as a new file owned by the caller with the list's mode, made by mktemp beside the list and renamed over it; nothing is synced | rewritten once per run when a line changes, keeping its owner (when permitted), mode and access ACL (access control list) entries; written beside the list, synced, renamed over it, and the directory synced, with `eb-keep-logs: cannot sync a .licensed-logs: ERROR` on stderr when that fails |
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
