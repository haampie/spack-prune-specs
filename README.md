
Utilities:

- `make buildcache-minus-pipelines.filelist`: specs in buildcache no longer referenced by develop pipelines in the last x days.
- `make buildcache-intersect-pipelines.filelist`: specs both in buildcache referenced by develop pipelines in the last x days.

Set `SINCE=yyy-mm-dd` to control the window (note that artifacts are removed after 30 days, so it can be max one month back).

`make` installs `aws`, `jq` and other utilities for you.


