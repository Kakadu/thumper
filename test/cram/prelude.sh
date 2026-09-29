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
