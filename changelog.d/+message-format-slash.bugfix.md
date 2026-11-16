`failed` names kept files with one slash after a LOGDIR given with trailing slashes, `logs/` as `logs/NAME...`, not `logs//NAME...`; the paths `rotate` joins to ROOT do the same.
