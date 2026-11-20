`lock` in `src/metrics.zig` delegates to `zig-common` `state.lockExclusive` instead of maintaining a local `flock` loop.
