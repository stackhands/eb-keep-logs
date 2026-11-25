CI and the release workflow install Python 3.14 before the steps that run `test_syslog.py` and `test_json_schemas.sh`, instead of relying on whichever Python version a runner image happens to carry.
