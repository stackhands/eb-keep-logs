# Trim an EasyBuild session log for a test fixture by dropping whole lines,
# never editing one. A record is a line "== DATE TIME FILE:LINE LEVEL ..."
# and the lines after it up to the next record. Kept: WARNING and ERROR
# records, and INFO records of EasyBuild's own messages, steps and shell
# commands (build_log.py, easyblock.py, run.py, main.py), less the output a
# successful command logged and the middle of a long failed command's output
# (its first 10 and last 150 lines stay).
function flush(   i, n) {
    if (!keep) { nbody = 0; return }
    print head
    n = nbody
    for (i = 1; i <= n; i++) {
        if (n > 160 && i > 10 && i <= n - 150) continue
        print body[i]
    }
    nbody = 0
}
/^== [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:,]+ [^ ]+ [A-Z]+ / {
    if (started) flush()
    started = 1
    head = $0
    keep = ($5 == "WARNING" || $5 == "ERROR" ||
            ($5 == "INFO" && $4 ~ /^(build_log|easyblock|run|main)\.py:/))
    quiet = (index($0, " completed successfully") > 0)
    next
}
{
    if (!started) { print; next }
    if (quiet) next
    body[++nbody] = $0
}
END { if (started) flush() }
