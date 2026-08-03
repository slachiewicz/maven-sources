#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# Per-mode git worktrees. The directory is the mode: each worktree sits on a
# `mode/<name>` branch with that mode's aggregator state committed, so nothing
# needs switching and no working tree is ever left dirty.
# This file is sourced, never executed.

CHECKOUT_ROOT="$(dirname "$SOURCES_DIR")"
BUILD_LOCK="${BUILD_LOCK:-$CHECKOUT_ROOT/.mvn-build.lock}"

# worktree_path MODE -> the sibling directory for MODE
worktree_path() {
  local mode="$1"
  mode_path "$mode" >/dev/null          # dies if the mode does not exist
  # A SIBLING of sources/ is mandatory. Aggregator modules are referenced as
  # ../../../core/... and resolve against the checkout root, so a worktree at
  # any other depth silently resolves modules to the wrong directories.
  printf '%s/sources-%s\n' "$CHECKOUT_ROOT" "$mode"
}

worktree_branch() { printf 'mode/%s\n' "$1"; }

# build_lock_acquire -> 0 when the checkout-wide build lock is held by us
# All worktrees drive the SAME module directories and one ~/.m2, so two
# concurrent builds overwrite each other's target/ trees and install the same
# GAVs over one another. That corrupts silently rather than failing, so the
# lock is a hard gate, not a warning.
#
# The lock is a SYMLINK whose target is the holder's pid, not a directory
# with a pid file inside it. `ln -s` is a single atomic syscall that creates
# the link AND sets its content in one step — there is no window where the
# lock exists but its owner is not yet recorded. A directory-based lock
# (`mkdir "$BUILD_LOCK"` then a SEPARATE `printf > "$BUILD_LOCK/pid"`) has
# exactly that window: a rival that reads the pid file between those two
# steps sees it empty, concludes the holder is dead, and steals a lock that
# is in fact being actively (and successfully) claimed right now. Verified
# empirically under 10-way concurrency: the mkdir-based recreate step
# admitted 2 simultaneous "winners" in real runs; ln -s does not, because a
# rival can never observe a symlink after it exists but before its target is
# set — those two things happen in the same kernel call. `mkdir` remains
# unusable here for a different reason (no flock(1) on macOS), but the same
# atomicity gap applies to it just as much as to any other create-then-
# populate sequence.
# A second, content-free mutex used ONLY to serialize the decide-whether-
# stale-and-maybe-replace section below. Why a lock needs its own lock:
# reading the holder and then acting on that reading are two separate steps,
# so between them some OTHER racer's reading of the SAME state can also
# conclude "stale". If each racer independently vacates $BUILD_LOCK to
# inspect it (moving it aside, checking, and putting it back when it turns
# out to still be live), $BUILD_LOCK is briefly, genuinely ABSENT from the
# filesystem during that inspection — and any OTHER racer's plain `ln -s`
# fast-path above can slip into exactly that gap and legitimately succeed,
# becoming an accidental second winner even though neither racer did
# anything wrong in isolation. Verified empirically: exactly this sequence
# (a straggler seizes an already-reclaimed live lock, finds it alive, and
# while putting it back, a third racer's fast path fills the momentary
# vacancy) admitted 2 winners in a 10-way race in 4 of 100 runs.
# This arbiter closes that gap by ensuring only ONE racer is ever inside the
# "read, then maybe replace" section at a time, so $BUILD_LOCK itself is
# NEVER made absent: the section either does nothing (still live) or
# installs its replacement with the single atomic rename below.
# Derived fresh inside the function (not as a fixed top-level default): tests
# reassign $BUILD_LOCK after sourcing this file, and a default computed only
# once at source time would keep pointing at the ORIGINAL path forever.
build_lock_acquire() {
  if ln -s "$$" "$BUILD_LOCK" 2>/dev/null; then
    return 0
  fi
  # Held. If the holder is gone, the lock is stale and may be taken —
  # otherwise a crashed build wedges the checkout permanently.
  local holder
  holder="$(readlink "$BUILD_LOCK" 2>/dev/null || echo '')"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    log_error "another build is running in this checkout (pid $holder)"
    log_error "modes share module directories and ~/.m2; concurrent builds corrupt each other"
    return 1
  fi

  # Possibly stale — but that reading can itself go stale before we act on
  # it, so gate everything past this point behind the arbiter. The arbiter
  # carries no content (only its existence matters), so unlike the main
  # lock it cannot be "empty but claimed" — a crashed holder is told apart
  # from a slow one purely by age, which is safe here because the section
  # it guards is a handful of local filesystem calls and never blocks.
  local arbiter="$BUILD_LOCK.steal-arbiter"
  if ! mkdir "$arbiter" 2>/dev/null; then
    local age
    age="$(( $(date +%s) - $(stat -f %m "$arbiter" 2>/dev/null || echo "$(date +%s)") ))"
    if [ "$age" -lt 5 ]; then
      return 1
    fi
    rmdir "$arbiter" 2>/dev/null   # best-effort; if this loses to another
                                   # reclaimer, the mkdir below is the real gate
    mkdir "$arbiter" 2>/dev/null || return 1
  fi

  # Sole owner of the arbiter from here on: no other racer's steal logic can
  # be running concurrently, so nothing else can move $BUILD_LOCK out from
  # under this section. Re-read fresh — the earlier reading may already be
  # out of date by the time the arbiter was won.
  holder="$(readlink "$BUILD_LOCK" 2>/dev/null || echo '')"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    rmdir "$arbiter" 2>/dev/null
    log_error "another build is running in this checkout (pid $holder)"
    log_error "modes share module directories and ~/.m2; concurrent builds corrupt each other"
    return 1
  fi

  # Genuinely stale. Prepare the replacement off to the side, then install
  # it with ONE atomic rename: `mv` onto an existing SYMLINK (unlike onto an
  # existing directory, which it moves itself inside rather than replacing —
  # confirmed empirically) replaces it outright, so $BUILD_LOCK is never
  # observably absent even for this final step.
  local candidate="$BUILD_LOCK.candidate.$$.$RANDOM.$RANDOM"
  ln -s "$$" "$candidate"
  if ! mv "$candidate" "$BUILD_LOCK" 2>/dev/null; then
    rm -f "$candidate"
    rmdir "$arbiter" 2>/dev/null
    log_error "failed to install the reclaimed build lock"
    return 1
  fi
  log_warn "reclaimed a stale build lock from pid ${holder:-unknown}"
  rmdir "$arbiter" 2>/dev/null
  return 0
}

build_lock_release() {
  [ -L "$BUILD_LOCK" ] || return 0
  # Only release a lock we own, so a stale-steal by another process is not
  # undone by the original holder exiting late. This compares against $$,
  # which is correct only because acquire and release both run in the same
  # top-level shell (build's, or a test's real process). `$$` inside a
  # `(...)` subshell reports the PARENT shell's pid, not the subshell's own
  # (that's `$BASHPID`) — confirmed: two sibling subshells forked from the
  # same parent both see the identical `$$`. So two DISTINCT processes that
  # each ran build_lock_acquire from a subshell of the same parent would
  # write and compare against that same inherited value, silently breaking
  # the "only the actual holder may release" invariant. Do not wrap these
  # calls in a subshell without re-checking this.
  local holder
  holder="$(readlink "$BUILD_LOCK" 2>/dev/null || echo '')"
  [ "$holder" = "$$" ] || return 0
  rm -f "$BUILD_LOCK"
}
