## bugfix/replication

* Fixed named replica rebootstrap after an unrecoverable applier error,
  including rebootstrap after deleting the replica from `_cluster`. The old
  applier remains stopped and keeps its original error (gh-12984).

## feature/replication

* Added `box.info.replication_upstreams`, an array describing all configured
  upstreams, including unregistered and unreachable instances. Each entry has
  the upstream status and connection diagnostics, with UUID, numeric ID, and
  instance name when known. This keeps stopped-applier errors visible after
  replica rebootstrap or removal from `_cluster` (gh-12984).
