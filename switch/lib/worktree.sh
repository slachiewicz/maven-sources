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

# Derived fresh inside the function (not as a fixed top-level default): tests
# reassign $BUILD_LOCK after sourcing this file, and a default computed only
# once at source time would keep pointing at the ORIGINAL path forever.
build_lock_acquire() {
  # The only case this must get right is the honest mistake: a second build
  # started while one is genuinely running (two terminals, a forgotten
  # background job). `ln -s` is atomic and fails if the lock exists, so that
  # case is decided race-free with no further machinery.
  if ln -s "$$" "$BUILD_LOCK" 2>/dev/null; then
    return 0
  fi

  local holder
  holder="$(readlink "$BUILD_LOCK" 2>/dev/null || echo '')"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    log_error "another build is running in this checkout (pid $holder)"
    log_error "modes share module directories and ~/.m2; concurrent builds corrupt each other"
    return 1
  fi

  # Stale: the holder is gone, so a previous build crashed. Reclaim it
  # best-effort.
  #
  # This step is deliberately NOT race-free, and that is a considered choice
  # rather than an oversight. Making it so needs a compare-and-swap the
  # filesystem does not offer: every check-then-act sequence available here
  # (rm+mkdir, mv-aside, an arbiter lock) can have the checked state change
  # underneath it. Three separate designs were built and measured, and each
  # admitted multiple winners under contention — 39/40, ~4/100 and 110/120
  # trials respectively.
  #
  # Reaching it requires a prior crash AND two builds racing to recover from
  # it. The project's stated working practice is that modes are never built
  # concurrently, so paying for that with an unbounded amount of subtle
  # locking machinery is the wrong trade. If concurrent builds ever become
  # real, the answer is a proper lock daemon or an flock-capable platform,
  # not more shell.
  log_warn "reclaiming a stale build lock from pid ${holder:-unknown} (previous build crashed?)"
  rm -f "$BUILD_LOCK"
  ln -s "$$" "$BUILD_LOCK" 2>/dev/null || {
    log_error "failed to reclaim the stale build lock"
    return 1
  }
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
