Built against `zig-common` 0.12.0: eb-keep-logs names its own identity (`eb-keep-logs`, `ebKeepLogs`) for the events it sends, through `syslog.emitFor`. The events are byte for byte what they were.
