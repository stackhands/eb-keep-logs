The forked unit tests' wait for the other side keeps one deadline: a signal that interrupts it no longer starts the full timeout over, so a stream of signals cannot extend it.
