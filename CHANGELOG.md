# Changelog

<!-- towncrier release notes start -->

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
