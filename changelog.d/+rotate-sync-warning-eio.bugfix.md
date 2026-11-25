A failed directory sync in `rotate`, after a log is compressed or after its `.licensed-logs` is rewritten, now reports its errno by name, such as `EIO` instead of `Unexpected`.
