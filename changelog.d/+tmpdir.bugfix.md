`failed` resolves `EASYBUILD_TMPDIR` before it checks that the failing command's output lies under it, so a symbolic link on the way to `EASYBUILD_TMPDIR` no longer drops the output.
