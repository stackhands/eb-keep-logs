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
It runs `eb --last-log` with `EASYBUILD_OUTPUT_STYLE=basic`, because EasyBuild 5 wraps that path too when its output is not a terminal, and again without it for an EasyBuild that has no output styles.

## Install

Copy `eb-keep-logs` onto `PATH`, or install it with its EasyBuild recipe.
It needs `bash`, coreutils, `find`, `gzip`, `awk` and, for `failed`, `eb`.

A static Zig build of the same tool needs nothing but `eb`.
Build it with Zig 0.17.1:

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

On a non-zero status this writes, next to `Foo-1.0.stdout.log`:

- `Foo-1.0.failed.ebout.log`, the EasyBuild log;
- `Foo-1.0.failed.command-out.txt` and `-err.txt`, the failing command's own output, when it lies under `EASYBUILD_TMPDIR`, with symbolic links resolved in both, and belongs to the build account; when it does not, `failed` says why;
- `Foo-1.0.failed.meson-testlog.txt`, the full meson test log, when a meson test step failed.

Each kept file is closed to others and listed in `$LOGDIR/.licensed-logs`, because a failed compile line of licensed software can print the licence number.
On status 0 it keeps nothing.

## Rotate a log tree

```bash
eb-keep-logs rotate /srv/build-logs --compress-after 30 --delete-after 365
```

`rotate` looks only at run directories named `YYYYMMDD_HHMMSS` directly under the root, and dates each run by its name.
It gzips the `*.log` and `*.txt` files of runs older than `--compress-after` days, keeps each file's mode, and updates the run's `.licensed-logs`.
It removes whole runs older than `--delete-after` days only when that option is given.

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
