## bugfix/replication

* Allow a named replica to rebootstrap after its applier on another instance
  has stopped with an error. Keep established connections and reconnecting
  appliers protected from registration replacement.
* Preserve the stopped upstream and its diagnostic on the replacement after
  commit. If the replacement already has an applier, retain both appliers
  under their respective UUIDs.
