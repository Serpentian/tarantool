## bugfix/replication

* Allow a named replica to rebootstrap after its applier on another instance
  has stopped with an error. Keep established connections and reconnecting
  appliers protected from registration replacement.
