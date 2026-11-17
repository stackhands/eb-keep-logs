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

A failed build's EasyBuild log stays in EasyBuild's tmpdir on the build node, which disappears with the job.
Parsing EasyBuild's stdout for the log path is unreliable, because EasyBuild wraps the "Results of the build can be found in the log file(s)" line.
`eb-keep-logs failed` asks `eb --last-log` for the path and keeps a copy.
It passes `--output-style=basic`, because EasyBuild 5.3 and later fold that path at the terminal width, 80 columns on a pipe; an `eb` older than 4.5 refuses the option and is asked again without it.

## Install

Each release has a static binary for `x86_64` and `aarch64` Linux, with `SHA256SUMS`.
It needs nothing but `eb`:

```bash
v=0.2.1 arch=x86_64
url=https://github.com/stackhands/eb-keep-logs/releases/download/v$v
curl -sSfL -O "$url/eb-keep-logs-$v-$arch-linux-musl" -O "$url/SHA256SUMS"
sha256sum --check --ignore-missing SHA256SUMS
install -m 0755 "eb-keep-logs-$v-$arch-linux-musl" ~/.local/bin/eb-keep-logs
```

The shell script `eb-keep-logs` in this repository is the same tool; copy it onto `PATH`.
It needs `bash`, coreutils, GNU `grep` (for `grep -P`), `sed`, `find`, `gzip`, `awk`, `flock` from util-linux for `rotate` and, for `failed`, `eb`.
Without `grep -P` it still keeps the log and the command output, but not the meson testlog.

There is no EasyBuild recipe for eb-keep-logs here or in the EasyBuild easyconfigs repository.
To install it as a module, write an easyconfig that installs a release binary and checks it against `SHA256SUMS`.

To build the binary instead, use Zig 0.17.1:

```bash
zig build -Drelease=true
zig-out/bin/eb-keep-logs --version
```

`zig build test` runs its unit tests, the shell test suite against the
binary, and `tests/differential.sh`, which runs the shell script and the
binary on the same invocations.
[COMPAT.md](https://github.com/stackhands/eb-keep-logs/blob/main/COMPAT.md) lists what the two share and where they differ on
purpose.

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

`EB_KEEP_LOGS_NOW`, in seconds since the epoch, sets the time `rotate` dates runs against.
On a copy of the tree, it previews what a later rotation compresses and removes:

```bash
cp -a /srv/build-logs /tmp/logs-preview
EB_KEEP_LOGS_NOW=$(date -d 2027-09-20 +%s) eb-keep-logs rotate /tmp/logs-preview --compress-after 30 --delete-after 365
```

## Find why a build failed

```bash
eb-keep-logs why --latest --root /srv/build-logs
eb-keep-logs why 20261117_040615 --root /srv/build-logs --target zen4 --json
```

`why` reads the logs a run kept, as `failed` kept them or `rotate` compressed them, and prints for each failed easyconfig its package and easyconfig, the EasyBuild step it failed in, EasyBuild's message, and the line of its log that shows the error, the first compiler or linker error or else EasyBuild's own error line, with the path, the line number and three lines either side.
For a failure class, feed the kept log to eb-stack.
`--json` prints the same as one line of JSON with `schema_version` 1, for a pipeline's run summary.
It is in the Zig build only.

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
| [eb-stack](https://github.com/stackhands/eb-stack) | Solve, shard and plan an EasyBuild build list; admit builds under a scratch inode budget | [docs](https://eb-stack.rgoswami.me/) |
| [eb-staged-rebuild](https://github.com/stackhands/eb-staged-rebuild) | Rebuild an installation in a staged tree and swap it in, so running jobs keep their paths | [docs](https://stackhands.github.io/eb-staged-rebuild/) |
| [eessi-arch-guard](https://github.com/stackhands/eessi-arch-guard) | Reload EESSI in a Slurm task that inherited it for another CPU or GPU | [docs](https://stackhands.github.io/eessi-arch-guard/) |
| [eb-local](https://github.com/stackhands/eb-local) | Install software with EasyBuild on top of EESSI into a directory a user or project owns | [docs](https://stackhands.github.io/eb-local/) |
| **eb-keep-logs** | Keep a failed build's EasyBuild log and command output; rotate a pipeline's log tree | [docs](https://stackhands.github.io/eb-keep-logs/) |
| [rfc9162](https://github.com/stackhands/rfc9162) | Append-only Merkle logs hashed as RFC 9162, with tiled storage and signed checkpoints | [docs](https://stackhands.github.io/rfc9162/) |
| [zig-common](https://github.com/stackhands/zig-common) | The shared Zig library under the Zig tools: system calls, checked files, child processes | [docs](https://stackhands.github.io/zig-common/) |
<!-- stackhands:end -->
