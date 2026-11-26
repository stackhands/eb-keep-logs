`rotate` removes an empty run directory it cannot read once the
run is past `--delete-after`. The removal used to stop when opening
that directory failed, so the run stayed. An empty directory inside
the run is removed too. A run that still contains entries is reported
and kept.
