The shell tests share one `check` helper in `tests/lib/check.sh` instead of each keeping its own copy, and CI runs shellcheck on it.
