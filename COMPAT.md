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
| environment | `PATH` (finds `eb`), `EASYBUILD_TMPDIR`, `EB_KEEP_LOGS_NOW`, `TZ`, `TZDIR`; `eb --last-log` runs with `EASYBUILD_OUTPUT_STYLE=basic`, and when that fails once more without the variable |
| stdout | `Failed build log: LOGDIR/NAME.failed.ebout.log`, `Failed command output: LOGDIR/NAME.failed.command-{out,err}.txt`, `Failed meson test log: LOGDIR/NAME.failed.meson-testlog.txt`, `Failed command output not kept: EASYBUILD_TMPDIR is not set.`, `Failed command output not kept: PATH is not under EASYBUILD_TMPDIR.`, `Failed command output not kept: PATH belongs to another user.`, `No EasyBuild log to keep for NAME.`, `No EasyBuild log to keep for NAME: eb is not on PATH.`, `No EasyBuild log to keep for NAME: eb --last-log exited N.`, `eb-keep-logs rotate: N files compressed, M runs deleted under ROOT` |
| files | kept files closed to others (command streams mode 0600), their resolved paths appended to `LOGDIR/.licensed-logs`; `rotate` writes `FILE.gz` with the file's mode and updates `.licensed-logs` to the `.gz` path |
| run ages | days from the local midnight of the date in the run's name, as `date -d YYYYMMDD` computes it, including TZ rules; a run whose local midnight does not exist is skipped |

## Deliberate differences

| case | shell script | Zig build |
|---|---|---|
| no arguments, `--help` | prints a trailing half sentence from the script's header | stops after the `--version` line |
| `--version` | `eb-keep-logs 0.1.0` | `eb-keep-logs 0.2.1 (TARGET, MODE, zig VERSION, COMMIT)`; the first two words are unchanged |
| `--compress-after` or `--delete-after` with no value after it | never returns | refused, exit 2 |
| `EB_KEEP_LOGS_NOW` not an integer | evaluated as shell arithmetic | refused, exit 2 |
| a copy into LOGDIR fails | error from cp, then the file is still listed and reported | error on stderr; the file is neither listed nor reported |
| a copy into an existing LOGDIR file fails part way (a full disk) | cp truncates the file first, so the previous bytes are gone | the previous file is left unchanged; nothing is listed or reported |
| a symbolic link or non-regular file at a destination name in LOGDIR | cp writes through it | refused, reported on stderr |
| the failing command's streams | checked by path (`realpath`, `-L`, `stat`), then copied | opened without following a symbolic link at the last component; the same checks run on the open file, and that file is copied |
| `.licensed-logs` after `rotate` | rewritten by every compressed file, as a new file owned by the caller | rewritten once per run when a line changes, keeping its owner (when permitted), mode and access ACL (access control list) entries, replaced atomically |
| a run directory that cannot be removed | counted as deleted | reported on stderr, not counted |
| compression | runs `gzip -9`, `find` and `awk` | in process; the gzip header (name, mtime, flags, OS) matches `gzip -9`, the compressed bytes differ; a file with other hard links or an existing `.gz` is skipped as gzip skips it |
| `eb --last-log` that does not return | waits without a limit | its process group is killed after 300 s, and nothing is kept |
| a log larger than 1 GiB | scanned | copied, not scanned for the command output or meson paths, with a message on stderr |
| a log with NUL bytes | `grep` reports a binary match and the scan finds nothing | scanned as text |
