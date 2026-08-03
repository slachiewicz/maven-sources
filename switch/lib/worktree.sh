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
# `mkdir` is the primitive because macOS has no flock(1).
build_lock_acquire() {
  if mkdir "$BUILD_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$BUILD_LOCK/pid"
    return 0
  fi
  # Held. If the holder is gone, the lock is stale and may be taken —
  # otherwise a crashed build wedges the checkout permanently.
  local holder
  holder="$(cat "$BUILD_LOCK/pid" 2>/dev/null || echo '')"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    log_error "another build is running in this checkout (pid $holder)"
    log_error "modes share module directories and ~/.m2; concurrent builds corrupt each other"
    return 1
  fi
  log_warn "removing stale build lock from pid ${holder:-unknown}"
  rm -rf "$BUILD_LOCK"
  mkdir "$BUILD_LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$BUILD_LOCK/pid"
  return 0
}

build_lock_release() {
  [ -d "$BUILD_LOCK" ] || return 0
  # Only release a lock we own, so a stale-steal by another process is not
  # undone by the original holder exiting late.
  local holder
  holder="$(cat "$BUILD_LOCK/pid" 2>/dev/null || echo '')"
  [ "$holder" = "$$" ] || return 0
  rm -rf "$BUILD_LOCK"
}
