# Releasing

A release is a tag `vX.Y.Z` on `main`. The `release` workflow builds the
static binaries for x86_64 and aarch64, tests each on its own architecture,
checks the version string against the tag, and opens a draft release with the
binaries, `SHA256SUMS` and build provenance attestations.

Release builds are reproducible: the same commit built with Zig 0.17.1 gives
byte-identical binaries, so anyone can check a published binary by building
the tag and comparing the sha256.

`cog bump` does the mechanical part. `cog.toml` runs `tools/release-prepare`
before the bump commit; the script's header lists what it sets and what it
leaves to a person.

## Steps

1. Branch from `main`: `git switch -c chore/release-X.Y.Z origin/main`.
2. Edit, in a commit of its own, the prose the hook leaves alone: the README
   sentence on what `main` has that the latest release lacks, the
   "Release X.Y.Z runs ..." rows of `docs/orgmode/howto/install.org`, the
   `--version` example of `docs/orgmode/reference/cli.org`.
3. `cog bump --minor` (or `--patch`, `--major`, `--version X.Y.Z`). It runs
   the hook, commits `chore(version): X.Y.Z` and creates the tag on that
   commit. `cog bump --minor --dry-run` prints the version only.
4. Push the branch, open the pull request, and merge it with a merge commit
   once its checks pass, so the tagged commit is on `main`.
5. Sign the tag and push it:
   `git tag -s -f vX.Y.Z -m "eb-keep-logs X.Y.Z" 'vX.Y.Z^{}' && git push origin vX.Y.Z`.
6. Check the draft release: two binaries, `SHA256SUMS`, attestations
   (`gh attestation verify FILE --repo stackhands/eb-keep-logs`).
7. Build the tag locally with `zig build -Drelease=true -Dcommit=<7-char sha>
   -Dtarget=x86_64-linux-musl` and compare its sha256 with `SHA256SUMS`.
8. Publish the draft.
9. Where a site keeps an EasyBuild recipe for eb-keep-logs (none is
   published), update it: version and the checksum of each binary from
   `SHA256SUMS`, then test-install it.
