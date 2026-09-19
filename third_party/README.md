# third_party/

Optional drop-in location, kept out of git (see .gitignore).

`bench/` and `variants/` depend only on the Python standard library, so nothing
is required here for the pipeline to run.

The FlameGraph toolkit is cloned separately to `$FLAMEGRAPH_DIR`
(default `~/FlameGraph`) by `setup/02_get_flamegraph.sh`, rather than vendored,
to keep this repository's history clean and its upstream licence intact.
