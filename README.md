<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/logo/logo-dark.svg">
    <img src="branding/logo/logo-light.svg" alt="eb-keep-logs" width="420">
  </picture>
</p>

# eb-keep-logs

<!-- docs:start -->
Keep the logs of EasyBuild builds that a build pipeline would otherwise lose, and keep the pipeline's log tree bounded.

Documentation: <https://stackhands.github.io/eb-keep-logs/>

For the EasyBuild log alone you do not need this tool.
Give `eb` a `--tmp-logdir` on durable storage and copy the file `eb --last-log` names, as EESSI's [`EESSI-install-software.sh`](https://github.com/EESSI/software-layer-scripts/blob/main/EESSI-install-software.sh) does after a failed build.

The EasyBuild log already holds a failed command's output.
What it does not hold is a failed meson test step's full test log, which stays in the build directory and goes with the job's node-local disk.
`eb-keep-logs failed` keeps that log, the failing command's `out.txt` and `err.txt` from `run-shell-cmd-output/` as plain files, and the EasyBuild log, closed to other users and listed in `.licensed-logs`, because a failed compile line of licensed software can print the licence number.
It asks `eb --last-log` for the log's path rather than parsing stdout, where EasyBuild wraps the "Results of the build can be found in the log file(s)" line.
It passes `--output-style=basic`, because EasyBuild 5.3 and later fold that path at the terminal width, 80 columns on a pipe; an `eb` older than 4.5 refuses the option and is asked again without it.

## Install

Each [release](https://github.com/stackhands/eb-keep-logs/releases/latest) has a static binary for `x86_64` and `aarch64` Linux, with `SHA256SUMS`.
The latest tag is v0.3.1.
It needs nothing but `eb`:

```bash
v=0.3.1 arch=x86_64
url=https://github.com/stackhands/eb-keep-logs/releases/download/v$v
curl -sSfL -O "$url/eb-keep-logs-$v-$arch-linux-musl" -O "$url/SHA256SUMS"
sha256sum --check --ignore-missing SHA256SUMS
install -m 0755 "eb-keep-logs-$v-$arch-linux-musl" ~/.local/bin/eb-keep-logs
```

The binary is the one implementation. The shell script it was ported from, 0.1.0, is no longer in the repository; [COMPAT.md](https://github.com/stackhands/eb-keep-logs/blob/main/COMPAT.md) lists what the binary keeps of its interface and where it differs.
Without `grep -P` it still keeps the log and the command output, but not the meson testlog.

There is no EasyBuild recipe for eb-keep-logs here or in the EasyBuild easyconfigs repository.
To install it as a module, write an easyconfig that installs a release binary and checks it against `SHA256SUMS`.

To build the binary instead, use Zig 0.17.1:

```bash
zig build -Drelease=true
zig-out/bin/eb-keep-logs --version
```

`zig build test` runs its unit tests, the shell test suites against the
binary, and `tests/test_cases.sh`, which compares the binary's output on
fixed invocations with the expected output under `tests/golden/cases`.

## Keep a failed build's logs

Run `eb` with `--tmp-logdir` pointing at a durable directory, then pass its exit status:

```bash
eb Foo-1.0.eb --tmp-logdir="$LOGDIR/easybuild-logs/Foo-1.0" 2>&1 | tee "$LOGDIR/Foo-1.0.stdout.log"
eb-keep-logs failed "${PIPESTATUS[0]}" Foo-1.0 "$LOGDIR" "$LOGDIR/easybuild-logs/Foo-1.0"
```

Without the last argument, `eb --last-log` names the newest log in EasyBuild's default place, which can be a later build's.
A log that shows EasyBuild processing easyconfigs but never names `Foo-1.0.eb` is another build's: `failed` keeps nothing from it and says so, and still keeps the command output that `Foo-1.0.stdout.log` names.

On a non-zero status this writes, next to `Foo-1.0.stdout.log`:

- `Foo-1.0.failed.ebout.log`, the EasyBuild session log `eb --last-log` names: the log of the whole `eb` run, not the shorter `easybuild-Foo-1.0-*.log` EasyBuild writes for the easyconfig in the `--tmp-logdir`;
- `Foo-1.0.failed.command-out.txt` and `-err.txt`, the failing command's own output, when it lies under `EASYBUILD_TMPDIR`, with symbolic links resolved in both, and belongs to the build account; when it does not, `failed` says why;
- `Foo-1.0.failed.meson-testlog.txt`, the full meson test log, when a meson test step failed.

Each kept file is closed to others and listed in `$LOGDIR/.licensed-logs`, because a failed compile line of licensed software can print the licence number.
The same lines are in `Foo-1.0.stdout.log` and in the logs EasyBuild writes to the `--tmp-logdir`, so `failed` closes `Foo-1.0.stdout.log` to others too, and the `--tmp-logdir` with the files directly in it when it lies below `$LOGDIR`, as above.
On status 0 it keeps and changes nothing.

## Rotate a log tree

```bash
eb-keep-logs rotate /srv/build-logs --compress-after 30 --delete-after 365
```

`rotate` looks only at run directories named `YYYYMMDD_HHMMSS` directly under the root, and dates each run by its name.
It gzips the `*.log` and `*.txt` files of runs at least `--compress-after` days old, keeps each file's mode, and updates the run's `.licensed-logs`, writing each new list beside the old one and renaming it over it.
It removes whole runs at least `--delete-after` days old only when that option is given.
It leaves alone the run it writes into, which is still going: the run that holds its standard output or error, and the run that holds `EB_PIPELINE_LOG_DIR`, the log directory `eb-pipeline` exports, because srun passes the output on over a pipe.
It also leaves alone every run that a process on the same host has a file in open for writing, as a build that is still going has its log, whichever run started the rotation: it finds them in `/proc/PID/fd`, for the processes whose descriptors it may read.
A later `rotate` takes such a run.

Rotations of one tree take turns: each holds an exclusive flock on `ROOT/.eb-keep-logs-rotate.lock` while it runs.
One that starts while another runs waits for it, up to `--lock-timeout` seconds (600; `0` does not wait), and when the wait runs out it changes nothing and exits 75.
`eb-pipeline`'s `ROOT/.eb-pipeline-rotate.lock` is a separate lock, which `rotate` never takes; a daily job that should wait for eb-pipeline's runs takes that lock around `rotate` with `flock`.

`--dry-run` prints each file that would be compressed and run that would be deleted, but changes nothing, creates no lock and emits no syslog or journal event.
`EB_KEEP_LOGS_NOW`, in seconds since the epoch, sets the time `rotate` dates runs against, so the two together preview a later rotation:

```bash
EB_KEEP_LOGS_NOW=$(date -d 2027-09-20 +%s) \
  eb-keep-logs rotate /srv/build-logs --compress-after 30 --delete-after 365 --dry-run
```

## Find why a build failed

```bash
eb-keep-logs why --latest --root /srv/build-logs
eb-keep-logs why 20261117_040615 --root /srv/build-logs --target zen4 --json
eb-keep-logs history hello --root /srv/build-logs
eb-keep-logs failures --package hello --since 2026-11-17 --root /srv/build-logs
```

`why` reads the logs a run kept, as `failed` kept them or `rotate` compressed them, and prints for each failed easyconfig its package and easyconfig, the EasyBuild step it failed in, EasyBuild's message, and the line of its log that shows the error, the first compiler or linker error or else EasyBuild's own error line, with the path, the line number and three lines either side.
For a failure class, feed the kept log to eb-stack.
`history` lists each kept build of a package, run by run, with its outcome and how long EasyBuild took, and accepts `--since`, `--until` and `--failed`.
`failures` lists failed builds across runs with their failed EasyBuild step and duration, filtered by `--package`, `--target`, `--since` and `--until`; `why` accepts `--package`, `--since` and `--until` as well.
`--json` prints any of these as one line of JSON with `schema_version` 1, for a pipeline's run summary.
All three are in the Zig build only.

Four more commands read records other tools wrote, and are in the Zig build only:

- `eb-keep-logs loads --module NAME FILE` prints who loaded a module, from Lmod's ModuleUsageTracking lines.
- `eb-keep-logs runs --exec PATH FILE` prints who ran an executable, from XALT run records.
- `eb-keep-logs pending FILE` prints what an `eb --dry-run` or `--missing-modules` report still has to build.
- `eb-keep-logs used --prefix PREFIX FILE...` lists the paths under a prefix that XALT and Lmod records name.

Two commands compare test runs, also in the Zig build only:

- `eb-keep-logs test-bundle` writes one JSON evidence bundle for a test run: its id, suite revision, EESSI target, stdout and stderr files, modules, seed and allocation.
- `eb-keep-logs test-compare BUNDLE...` lists which evidence fields differ across two or more bundles, without deciding pass or fail.

## Emit syslog and journald events, and metrics

Pass `--metrics-file PATH` to `failed` or `rotate` to update Prometheus counters for the logs and bytes kept, atomically; `rotate --dry-run` writes none.

Pass `--syslog TARGET` (or set `EB_KEEP_LOGS_SYSLOG`) to `failed` or `rotate` to emit structured RFC 5424 messages (`ebKeepLogs@<PEN>`, with `EB_KEEP_LOGS_SYSLOG_PEN` defaulting to `32473`, the IANA RFC 5398 documentation placeholder until a site or project PEN is assigned) or native `systemd-journald` fields (`journald`, `syslog`, `unix:///path`, `journal+unix:///path`, `udp://host:port`, `tcp://host:port`) with stable `MSGID` values (`EB_KEEP_FAILED`, `EB_KEEP_NONE`, `EB_ROTATE_DONE`) without copying log file contents into syslog.

## Plan module lifecycle from usage

`eb-keep-logs usage` compares installed `Name/Version` directories against XALT and Lmod records, and `eb-keep-logs lifecycle --policy policy.toml usage.json` turns that report into a reviewable `keep`, `warn`, `forbid-after`, and `candidate-remove` plan plus Lmod `.modulerc.lua` warnings and forbids.
It never deletes software or modulefiles, enforces the policy's `min_observation_days`, and calls `eb-stack rebuild-set` when given `--easyconfigs` to identify installed dependents before permitting `candidate-remove`.

## Tests

```bash
bash tests/test_eb_keep_logs.sh
```

## License

MIT

<!-- stackhands:begin -->
## Part of stackhands

eb-keep-logs is one of the [stackhands](https://github.com/stackhands) tools for building, installing and maintaining an HPC software stack with EasyBuild on top of EESSI.

| Tool | Job | Docs |
|---|---|---|
| [eb-stack](https://github.com/stackhands/eb-stack) | Turn conda-forge, Spack, PyPI, CRAN and Cargo recipes into easyconfigs; solve, shard and plan an EasyBuild build list | [docs](https://eb-stack.rgoswami.me/) |
| [eb-staged-rebuild](https://github.com/stackhands/eb-staged-rebuild) | Rebuild an installation beside the live one and swap it in, for a stack outside CernVM-FS that jobs read during the rebuild | [docs](https://stackhands.github.io/eb-staged-rebuild/) |
| [eessi-arch-guard](https://github.com/stackhands/eessi-arch-guard) | Reload EESSI in a Slurm task that inherited a stack loaded for another CPU or GPU, as srun from a login shell does | [docs](https://stackhands.github.io/eessi-arch-guard/) |
| [eb-local](https://github.com/stackhands/eb-local) | Build on EESSI-extend inside a Slurm job's node-local disk, compile your own code with RPATH, list and uninstall per CPU target | [docs](https://stackhands.github.io/eb-local/) |
| **eb-keep-logs** | Keep a failed EasyBuild command's own output, which --tmp-logdir does not; rotate a pipeline's log tree | [docs](https://stackhands.github.io/eb-keep-logs/) |
| [eb-pipeline](https://github.com/stackhands/eb-pipeline) | Drive a site's EasyBuild builds from one site file, through eb-stack, eb-staged-rebuild and eb-keep-logs | [docs](https://stackhands.github.io/eb-pipeline/) |
| [rfc9162](https://github.com/stackhands/rfc9162) | Append-only Merkle logs hashed as RFC 9162, with tiled storage and signed checkpoints | [docs](https://stackhands.github.io/rfc9162/) |
| [zig-common](https://github.com/stackhands/zig-common) | The shared Zig library under the Zig tools: system calls, checked files, child processes | [docs](https://stackhands.github.io/zig-common/) |
<!-- stackhands:end -->
