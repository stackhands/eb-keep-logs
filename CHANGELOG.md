# Changelog

<!-- towncrier release notes start -->

## 0.3.1 (2026-11-24)

### Fixes

- The `used` command counts a path equal to the install prefix when the prefix ends in a slash, so the require-none check exits 2 when that path is the only hit.
- `failed` and `rotate` keep updating a metrics file when a sample carries a timestamp after its value, or a tab between its name and its value, instead of leaving the counters unchanged.
- `failed` stops a Meson build-directory match before an invalid byte when grep uses a UTF-8 locale, so it does not keep a test log from a path the shell reader ignores.
- `rotate` counts a log as compressed once its `.gz` is renamed into place and the original is removed, even when the directory sync that follows for crash durability fails; a warning still names the archive so the failure stays visible.
- `rotate` no longer aborts when the environment variable `EB_KEEP_LOGS_NOW` names a time whose distance from a run's local midnight overflows a signed sixty-four bit integer. The age now saturates at that integer's minimum or maximum instead, as far from old enough to compress or delete as it can be in that direction.
- `rotate` updates each run's `.licensed-logs` right after that file's own compression, the way the shell script does, instead of waiting for every file under the run to finish first. A kill partway through a run with several files to compress no longer leaves an already compressed file's line pointing at its old, since removed, name forever. Each update touches only the `.licensed-logs` beside the file just compressed, so the per file cost stays flat instead of growing with the size of the run.
- `why` and `history` count a day in EasyBuild's `(took DURATION)` as 86400 seconds, so a build that ran for a day keeps its duration.

### Documentation

- `COMPAT.md` now lists a compress after count paired with a delete after count past what a signed sixty-four bit integer holds as a deliberate difference: `rotate` accepts the pair and treats the run as never old enough for the delete after count to delete it, where the shell script's own check that the delete after count is later than the compress after count errors on that count before it can tell, refusing the whole invocation even though the count genuinely is later.
- `COMPAT.md` now lists a compress after count past what a signed sixty four bit integer holds, given on its own without a delete after count, as a deliberate difference: `rotate` prints the final compressed and deleted count on standard output alone, treating the run as never old enough to compress, where the shell script's own check that a run is old enough to compress errors with an "integer expression expected" message, once for every run under the given root, before that same final count.
- `COMPAT.md` now lists a compress after or delete after count naming more days than an unsigned sixty-four bit integer holds as a deliberate difference: `rotate` refuses that count with exit status two, where the shell script's own comparison of it errors, is read as false, and leaves every run untouched.
- `COMPAT.md` records what a kill during `rotate`'s compression leaves behind. The shell script's `gzip` writes under the final `FILE.gz` name as it goes, so a kill leaves a partial archive there that every later rotation declines to redo, printing `gzip: FILE.gz already exists; not overwritten` each time. The Zig build writes to a private, randomly named file first and renames it over `FILE.gz` only once its bytes are down and synced, so a kill leaves the source file untouched and that private file behind, unlisted and unused, and the next rotation compresses the file as usual.

### Miscellaneous

- The `--modulerc-out` writer publishes through zig-common
  `atomic.atomicWrite`, which keeps the mode, refuses a symlink and syncs,
  instead of its own temporary file, with the refusal text carried to the
  tool's die.
- The crash mid-compress case in the differential suite used to kill each side after a fixed pause, guessed to land after compression had begun. Each side is killed as soon as its own destination for the file exists instead, found by polling rather than by guessing how long that takes.
- `lock` in `src/metrics.zig` delegates to `zig-common` `state.lockExclusive` instead of maintaining a local `flock` loop.


## 0.3.0 (2026-11-19)

### Features

- Add `test-bundle` and `test-compare` to capture and compare normalized flaky-test evidence bundles across sites, with schema-versioned JSON outputs and documentation.
- Add opt-in atomic Prometheus textfile metrics for kept logs, kept bytes, and the last completed rotation.
- Emit structured RFC 5424 syslog or native `systemd-journald` events (`--syslog`, `EB_KEEP_LOGS_SYSLOG`) with stable `MSGID` values (`EB_KEEP_FAILED`, `EB_KEEP_NONE`, and `EB_ROTATE_DONE`) and configurable RFC 5424 `SD-ID` enterprise number (`EB_KEEP_LOGS_SYSLOG_PEN`, defaulting to the RFC 5398 documentation PEN `32473`) when `failed` keeps or closes logs and when `rotate` compresses or removes runs.
- `eb-keep-logs failures` and opt-in `--package`, `--since`, `--until` and `--failed` filters on `why` and `history` filter failed builds across `YYYYMMDD_HHMMSS` runs by recipe or date, with schema-validated `--json` output and unchanged default command outputs.
- `eb-keep-logs history PACKAGE [--target TARGET] [--root ROOT] [--json]` lists each kept build of a package, oldest run first, with its target, its outcome and how long EasyBuild took, from EasyBuild's output, plain or compressed; `PACKAGE` is an easyconfig's name, its start up to a dash, or a module name. `--json` prints one line with `schema_version` 1. Like `why`, it is in the Zig build only; the shell script refuses it.
- `eb-keep-logs lifecycle` reads `usage --json` output and a TOML policy to emit a reviewable `keep`, `warn`, `forbid-after`, and `candidate-remove` plan plus Lmod `.modulerc.lua` warnings and forbids without deleting files, enforcing a minimum observation window and checking installed dependents via `eb-stack rebuild-set`.
- `eb-keep-logs loads --module NAME FILE` prints who loaded `NAME`, from Lmod's ModuleUsageTracking lines in `FILE`. A log with no such load prints `no load of NAME`. The shell script has no `loads`; the Zig build does.
- `eb-keep-logs rotate --dry-run` lists the log files it would compress and run directories it would delete without changing the tree, creating its lock file, emitting an event, or writing metrics.
- `eb-keep-logs usage` classifies installed `Name/Version` software as active or unused from XALT and Lmod records, with epoch filtering, JSON output and an active listing accepted by `eb-stack stack gap --site`.
- `eb-keep-logs used --prefix PREFIX FILE...` lists paths under `PREFIX` from XALT run, library, link and package records and from Lmod module-usage lines, with a last-seen time and count per path. `--json` prints one document. `--require-none` exits 2 when anything is listed. The shell script has no `used`.
- `eb-keep-logs why [RUN | --latest] [--target TARGET] [--root ROOT] [--json]` says from a run's kept logs why its builds failed: for each failed easyconfig, the package and easyconfig, the EasyBuild step it failed in, EasyBuild's message, and the line of the log that shows the error, with three lines either side, its path and its line number. That line is the first compiler or linker error in the failed step, or else EasyBuild's own error line. It reads a log `rotate` compressed as it is, and a build that kept only its output from that, undoing EasyBuild's wrapping at 80 columns. `--json` prints the same as one line of JSON with `schema_version` 1, for a pipeline's run summary. The shell script refuses `why`, as COMPAT.md lists, and `tests/test_why.sh` checks it on the real failures in `tests/fixtures/build-logs/`.
- `loads`, `runs` and `pending` accept opt-in `--json` with `schema_version` 1. JSON Schema files under `docs/orgmode/reference/json/` describe every `--json` document (`why`, `history`, `loads`, `runs`, `used`, `usage`, `pending`). `tests/test_json_schemas.sh` validates command output against those schemas in CI.
- `pending FILE` prints what an EasyBuild `--dry-run` or `--missing-modules` report still has to build. `[x]` is left out. Nothing left prints `nothing to build`. The shell script refuses the command. It does not run `eb` and does not resolve dependencies.
- `runs --exec PATH FILE` prints who ran an executable, from XALT run records the site already has. A link record is skipped. No match prints `no run of PATH`. The shell script refuses the command. It does not record runs.

### Fixes

- A failed copy into `LOGDIR` leaves a file that was already there unchanged, instead of truncating it first.
- After a failure, `failed` also closes `NAME.stdout.log` to others, and TMP_LOGDIR with the files directly in it when it lies below LOGDIR: they hold the failed lines the kept copies are closed for, and EasyBuild writes its own logs to TMP_LOGDIR at 0644. Symbolic links are not followed; a TMP_LOGDIR elsewhere, and everything on success, is left as it is.
- The `rotate` summary says `1 file compressed` and `1 run deleted`.
- The shell script writes each new `.licensed-logs` to a file of its own, made by `mktemp` beside the list, and renames it over the list, where it wrote every new list to the fixed name `.licensed-logs.tmp`. Two rotations at once, as where the file system cannot lock, wrote into that one file together and could rename a torn list into place, and a symbolic link at that name was written through and then took the list's place. A temporary file is removed when the rewrite fails. The Zig build, which already wrote and synced a new list beside the old one and renamed it over it, now also syncs the list's directory, as it does for the files `failed` keeps, and says `cannot sync a .licensed-logs: ERROR` when that fails.
- When a `TZ` with a leading `:` names no zone file, as `:CET-1CEST,M3.5.0,M10.5.0/3` does, `rotate` reads the POSIX rule string after the `:`, as the shell script's `date` does, instead of dating runs in UTC.
- When a command failed but its output is not kept, `failed` says why: `EASYBUILD_TMPDIR` is not set, the output lies outside it, or it belongs to another user.
- Without TMP_LOGDIR, `failed` no longer keeps a later build's log, or the meson testlog it names, under this NAME. A log that shows EasyBuild processing easyconfigs but never names `NAME.eb` is refused with a message; the command output `NAME.stdout.log` names is still kept. The usage text and README say what happens without TMP_LOGDIR.
- `--help`, `-h` and no arguments print the whole usage, the same in both builds: the shell script no longer ends it with a blank line and half a sentence of its own header. It lists every option, `-h` and the `--OPTION=VALUE` forms included, with what each of `rotate`'s options defaults to (600 seconds for `--lock-timeout`), the environment variables the commands read and the exit statuses 0, 2 and 75, and it says that `rotate` takes the runs at least DAYS old, not the runs older than DAYS. COMPAT.md lists the usage as kept, no longer as a deliberate difference.
- `failed` keeps a log whose path is longer than 80 columns. EasyBuild 5.3 and later fold the `eb --last-log` path at the terminal width, 80 columns on a pipe, so `failed` took the last piece of the path, found no such file and kept nothing. It now asks with `--output-style=basic`, which prints the path whole, and asks again without it when `eb` refuses the option, as EasyBuild before 4.5 does.
- `failed` lists a kept file in `.licensed-logs` only when it is not listed yet, so a retried build that keeps the same files again no longer adds each of them once more.
- `failed` names kept files with one slash after a LOGDIR given with trailing slashes, `logs/` as `logs/NAME...`, not `logs//NAME...`; the paths `rotate` joins to ROOT do the same.
- `failed` no longer keeps a command's output that the session log records as completed successfully, as the last command before a sanity check failure is, nor a meson testlog whose summary shows every test passing. The output of a command the build died in, with no outcome logged, is still kept.
- `failed` resolves `EASYBUILD_TMPDIR` before it checks that the failing command's output lies under it, so a symbolic link on the way to `EASYBUILD_TMPDIR` no longer drops the output.
- `failed` runs `eb --last-log` with the basic output style, so EasyBuild 5 no longer wraps the log path and the log is kept when the build's output goes to a file or a pipe. An EasyBuild without output styles is asked again without it.
- `failed` says when `eb` is not on PATH or `eb --last-log` fails, instead of only that there is no log to keep.
- `rotate --dry-run` matches `rotate` path order and skips files with existing `.gz` siblings or multiple hard links.
- `rotate` holds an exclusive flock on `ROOT/.eb-keep-logs-rotate.lock` for the whole rotation, so two rotations of one tree no longer run at once. Started together, each compressed part of a run and wrote its `.licensed-logs` back over the other's changes, leaving lists that named files that were gone, and both exited 0. A second `rotate` now waits for the first, up to `--lock-timeout SECONDS` (600; `0` does not wait), then finds the work done; when the wait runs out it changes nothing and exits 75, naming the lock. A lock file that cannot be opened, or a symbolic link or non-regular file at its name, is refused with exit 2; on a file system that cannot lock, `rotate` says so and rotates without the lock. eb-pipeline's `ROOT/.eb-pipeline-rotate.lock` is a separate lock that `rotate` never takes, so the two cannot wait on each other.
- `rotate` leaves alone every run that a process on the same host has a file in open for writing, as a build that is still going has its log, not only the run it writes into itself. A build of another run that started before midnight UTC is a day old just after it, so with `--compress-after 1` a rotation from any other run compressed the EasyBuild log the build still wrote into, and the build exited 1 when it went to copy that log into the installation; past `--delete-after` such a run was removed. `rotate` reads the links in `/proc/PID/fd` of the processes whose descriptors it may read, and a later rotation takes the run once its build has ended. A process that only reads a run's files does not hold the run back.
- `rotate` leaves alone the run it writes into. A run that started before midnight is a day old just after it, so with `--compress-after 1` the rotate phase of an eb-pipeline run gzipped its own open `rotate.log` and lost its summary line, and past `--delete-after` it removed the run it was writing into. The run that holds rotate's standard output or error, or `EB_PIPELINE_LOG_DIR` when srun carries the output over a pipe, is left for the next rotate.
- `rotate` reads a malformed `TZ` rule string as far as the shell script's `date` reads it, instead of dating runs in UTC: text after the rules is ignored, a missing end rule is the first Sunday in November, and a rule cut short keeps what was read of it, as glibc keeps it. Rules also apply as glibc applies them, with the changes of the year in UTC, and up to 1970 with the changes of 1970.
- `rotate` takes an empty `EB_KEEP_LOGS_NOW` as unset and dates runs against the current time, as the shell script does, instead of refusing it with exit 2.
- `rotate` takes an empty `TZDIR` as unset and finds the zone `TZ` names under `/usr/share/zoneinfo`, as the shell script's `date` does, instead of looking it up relative to the working directory and dating runs in UTC when no file of that name is there.
- `usage` preserves `resultT` hits when `userT` is `null`, warns on unreadable `software` subdirectories, and refuses non-JSON non-Lmod files.
- `usage` recognizes interleaved XALT and Lmod records, matches relative or symbolic-link install roots with canonical record paths, and excludes malformed epoch times from `--since` windows.
- `why -h`, `why --help`, `history -h` and `history --help` print what those commands take and exit 0. Each says that `--root` defaults to the current directory and that a run is a directory named `YYYYMMDD_HHMMSS`.
- `why` says what to do when its default root holds no run: the directory it looked in, that a run is named `YYYYMMDD_HHMMSS`, and to pass `--root` or name one run. `history` with no package says to give the easyconfig name without `.eb`, or `NAME/VERSION`.

### Documentation

- A how-to, Find why a build failed, runs `why` and `history` on the kept logs of real failed builds, and reads `why --json` with `jq`; the front page and the pipeline how-to point to it.
- COMPAT.md has a section for differences between the Zig build and the shell script that are not choices, each with a command that shows it: a `TZ` rule string without rules where `TZDIR` holds a `posixrules` file, a rule month glibc reads out of bounds, zone files with leap seconds, and zone files unlike any of tzdata's. Its rows on `EB_KEEP_LOGS_NOW` and on run ages no longer claim more than the Zig build does.
- COMPAT.md lists a `date` other than GNU's among the deliberate differences: the shell script's run ages follow that `date`, and uutils' `date`, Ubuntu's from 25.10, reads as UTC some `TZ` rule strings that glibc reads, where the Zig build's run ages are GNU `date`'s whatever `date` is.
- Document `eb-keep-logs lifecycle` in the CLI reference, JSON schema reference, and a Diataxis how-to guide for planning reversible module deprecations.
- Document how to review unused installed software and use the complementary active listing as `eb-stack stack gap --site` input.
- Every `pub` declaration has a doc comment, whose first sentence is the summary the API pages list.
- README.md lists GNU `grep` (for `grep -P`) and `sed` among what the shell script needs, shows the release binary install, and says no EasyBuild recipe for eb-keep-logs is published; RELEASING.md follows.
- The README opens with what `--tmp-logdir` and `eb --last-log` already keep, and the command output and meson log this tool adds.
- The command-line reference shows the usage that `-h`, `--help` and no arguments print, which the suite checks against both builds, and its synopsis and exit statuses name `-h`. README.md says that `rotate` compresses and removes the runs at least DAYS old, as the usage and the reference do.
- The comments on `runAgeDays` in `src/main.zig` and on `_run_age_days` in the shell script give the right reason a run's age comes from its name, not its directory's mtime: compressing the run's logs moves the mtime, where a chmod changes only the ctime.
- The documentation site is built from Org pages in `docs/orgmode/` with Sphinx, in four parts: the tutorial "Keep a failed build's logs", how-to guides, explanation and reference. The API pages are generated from the doc comments of `src/main.zig` and the files it imports, and `zig build docs` installs the Zig autodoc site. `pixi run -e docs docbld` builds it as CI does and fails on a warning, an unresolved name or a dead internal link; `pixi run -e docs linkcheck` checks the external links. The `docs` workflow publishes the site to GitHub Pages; `docs/requirements.txt` and `pages.yml` are gone.
- The install how-to, the README release pointer and the tutorial install from source so `failed` works on EasyBuild 5.3 or newer and the next-step commands exist on `PATH`.
- The site has how-to guides for rotating a log tree and marking logs that may carry a licence number; an explanation of how a run's age is reckoned from its name in local time; and a reference of the `eb-keep-logs` command: its arguments, options, environment variables, exit statuses, every message it prints and the files it reads and writes.
- The tutorial that installs the shell script says that `why` and `history` are in the Zig build only, and points at the how-to that builds that program with `zig build -Drelease=true`.
- `--help` and README.md name the copy `failed` keeps as the EasyBuild session log `eb --last-log` names, and say that `EB_KEEP_LOGS_NOW` sets the time `rotate` dates runs against; README.md shows a preview with it.

### Miscellaneous

- A release is cut with `cog bump`: `cog.toml` runs `tools/release-prepare`, which builds the changelog and sets the version wherever the release workflow or a download command names it. `RELEASING.md` has the steps.
- Built against `zig-common` 0.12.0: eb-keep-logs names its own identity (`eb-keep-logs`, `ebKeepLogs`) for the events it sends, through `syslog.emitFor`. The events are byte for byte what they were.
- Built against zig-common 0.10.0, the version the other stackhands Zig tools use.
- The syslog and journald emitter comes from `zig-common` 0.11.0 (`zig_common.syslog`), which took it from this repository; `src/syslog.zig` is gone. Behaviour is unchanged.
- The tests' example build run keeps its logs under a target directory named `site-zen4`, not one named after a particular cluster.
- `tests/fixtures/build-logs/` holds the logs of real EasyBuild 5.4.2 builds on top of EESSI 2025.06 that fail at a checksum, a patch, a missing dependency, configure, a compile, a link, a test and a sanity check, laid out as eb-pipeline lays out its runs, with what `eb-keep-logs failed` kept and four runs compressed by `rotate`. `tests/corpus/` has the easyconfigs, the script that runs them and the one that trims the logs by dropping lines.
- `zig build test` passes when started in a subdirectory such as `src/`: the command-line suite and the differential run start their scripts from the build root instead of from where `zig build` was started, where bash stopped with `tests/test_eb_keep_logs.sh: No such file or directory`.
- `zig build test` passes when the directory it runs in has no `.zig-cache`, as when `ZIG_LOCAL_CACHE_DIR` puts the cache elsewhere: the unit test of a failed copy makes its scratch directory with its parents instead of failing with `NotFound`.
- `zig build test` passes where `date` is not GNU's, as on Ubuntu from 25.10, where uutils' `date` failed three checks of the command-line suite: the suite takes a run's local midnight under `TZ` from GNU `date` (`gnudate` there) and runs the tool with that `date`, and where there is no GNU `date` it skips those checks, saying so on stderr. A failed check of the suite or a difference in the differential run is printed on stderr, which `zig build test` shows, instead of on stdout, which it drops, and both run on every `zig build test`, as its cache sees neither their scripts nor the host's `date` and tzdata.


## 0.2.1

* A kept copy whose mode cannot be read is no longer set to mode 000.
* Built on zig-common 0.8.1; a default build targets the baseline CPU; the
  std names Zig 0.17 keeps, not its deprecated aliases.
* Release notes come from this file, and the tag must match `build.zig.zon`.
* CI pins actions to commit SHAs and runs with least-privilege tokens.
* Logo and a documentation site: <https://stackhands.github.io/eb-keep-logs/>.

## 0.2.0

* eb-keep-logs in Zig on zig-common: one static binary per architecture with
  the shell script's interface; `COMPAT.md` lists where they differ on
  purpose.

## 0.1.0

* The shell script: `failed` keeps a failed build's EasyBuild log and command
  output; `rotate` compresses and removes old runs of a log tree.
