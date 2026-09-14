#!/usr/bin/env bash
# fm-treehouse-capability-lib.sh - what the installed treehouse can actually do.
# This file is sourced and has no side effects on source.
#
# A per-home worktree pool root (bin/fm-treehouse-root.sh) is only real when the
# pool tool honors a configured root. A build without that support ignores
# TREEHOUSE_ROOT entirely and leases from the shared user-level pool, which is
# exactly the two-homes-one-pool collision the per-home root exists to remove,
# and it does so with no signal of its own: the spawn succeeds, the task record
# names a root the slot never came from, and the collision surfaces later as a
# refused claude spawn or a teardown that cannot return the slot.
#
# The probe reads the tool's own `get --help`, the same shape
# treehouse_supports_lease uses in bin/fm-bootstrap.sh, because a build that
# lists no --root flag has no root support at all. Verified against v2.0.1 (no
# match) and v2.3.0 (match); the lease probe matches on BOTH, so it cannot stand
# in for this one. See docs/verification/runtime-backends.md "Treehouse".
#
# Consumers: bin/fm-bootstrap.sh surfaces an upgrade at session start, and
# bin/fm-spawn.sh refuses a spawn that would otherwise share another home's pool.

treehouse_supports_root() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--root([^[:alnum:]_-]|$)'
}
