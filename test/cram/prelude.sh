# The environment every cram session states, sourced as its first command.
# A fixed machine key names the baseline's section; the measurement lock
# lives in the session's own directory; thumper's other inputs from the
# environment are unset. INSIDE_DUNE is kept in CONTEXT, so a session can
# restore the rule action's environment where that is its subject.

export THUMPER_MACHINE=testkey
mkdir -p locks
export THUMPER_LOCK_DIR="$PWD/locks"
CONTEXT="$INSIDE_DUNE"
unset INSIDE_DUNE DUNE_SOURCEROOT CI GITHUB_ACTIONS NO_COLOR TERM

# The summary line of the report in log $1, its duration written DURATION:
# the one way a session reads a summary, whatever else the log holds.
summary() {
  grep -E ' in [0-9.]+m?s(;.*)?\.$' "$1" |
    sed -E 's/ in [0-9.]+m?s/ in DURATION/'
}

# Polls every 20 ms until the command succeeds, for 60 s of wall clock at
# most, as long as hold_lock.exe holds the lock: no loop in a session
# outlives its holder.
wait_for() {
  deadline=$(($(date +%s) + 60))
  until "$@"; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.02
  done
}
