# Releasing

A release is a tag `vX.Y.Z` on `main`. The `release` workflow builds the
static binaries for x86_64 and aarch64, tests each on its own architecture,
checks the version string against the tag, and opens a draft release with the
binaries, `SHA256SUMS` and build provenance attestations.

Release builds are reproducible: the same commit built with Zig 0.17.1 gives
byte-identical binaries, so anyone can check a published binary by building
the tag and comparing the sha256.

## Checklist

1. `version` in `src/main.zig` and `.version` in `build.zig.zon` name the new
   version.
2. `README.md` and `COMPAT.md` describe this version; a new deliberate
   difference from the shell script has its row in `COMPAT.md` and its label
   in `tests/differential.sh`.
3. CI on `main` is green, both architectures.
4. Tag and push: `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`.
5. Check the draft release: two binaries, `SHA256SUMS`, attestations
   (`gh attestation verify FILE --repo stackhands/eb-keep-logs`).
6. Build the tag locally with `zig build -Drelease=true -Dcommit=<7-char sha>
   -Dtarget=x86_64-linux-musl` and compare its sha256 with `SHA256SUMS`.
7. Publish the draft.
8. Update the EasyBuild recipe: version and the checksum of each binary from
   `SHA256SUMS`, then test-install it.
