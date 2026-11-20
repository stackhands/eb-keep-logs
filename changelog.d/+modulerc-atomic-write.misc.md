The `--modulerc-out` writer publishes through zig-common
`atomic.atomicWrite`, which keeps the mode, refuses a symlink and syncs,
instead of its own temporary file, with the refusal text carried to the
tool's die.
