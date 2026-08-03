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
# Bundle every repository in the checkout into an archive directory that lives
# outside the checkout, so that a `repo init` onto a different manifest branch
# cannot take local-only work with it.

set -euo pipefail

CHECKOUT_ROOT="${CHECKOUT_ROOT:-$HOME/mvn4}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$HOME/mvn4-archive}"
MANIFEST="$ARCHIVE_DIR/MANIFEST.txt"
# Safety floor for the project count `repo forall` reports. The checkout has
# 134 projects at the time of writing; 100 tolerates the manifest shrinking
# over time while still catching the failure modes this floor exists for:
# `repo` missing from PATH, a broken/empty `.repo`, or `repo forall` erroring
# out after listing only a handful of projects. Override via env if the
# manifest legitimately drops below it.
MIN_REPOS="${MIN_REPOS:-100}"
# Override to proceed despite uncommitted/untracked work in some repository.
# Bundles capture committed objects only, so a deliberate run with this set
# means that work will NOT be in the archive.
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"

cd "$CHECKOUT_ROOT"

# `repo forall` sets REPO_PATH for each project. Capture its output (and exit
# status) in a real file rather than piping straight into the loop below: a
# pipeline's exit status is the last stage's (`sort`/`while read`), which
# happily exits 0 on empty input, so a failing or PATH-missing `repo` would
# otherwise be indistinguishable from a clean run of zero repositories.
list_file=$(mktemp "${TMPDIR:-/tmp}/mvn4-archive-projects.XXXXXX")
trap 'rm -f "$list_file"' EXIT

if repo forall -c 'echo "$REPO_PATH"' 2>/dev/null > "$list_file"; then
  status=0
else
  # `!` before a command normalises $? to a boolean for the `if`, so it must
  # be captured here, in the `else` branch, where it is still the real exit
  # status of `repo forall` itself.
  status=$?
fi
if [ "$status" -ne 0 ]; then
  echo "ERROR: 'repo forall' exited with status $status." >&2
  echo "Refusing to report success — check that 'repo' is on PATH and that '$CHECKOUT_ROOT/.repo' is a valid repo checkout." >&2
  exit 1
fi

if [ ! -s "$list_file" ]; then
  echo "ERROR: 'repo forall' produced no project paths." >&2
  echo "Refusing to report success — check that 'repo' is on PATH and that '$CHECKOUT_ROOT/.repo' is a valid repo checkout." >&2
  exit 1
fi

sort -o "$list_file" "$list_file"

discovered=$(wc -l < "$list_file" | tr -d ' ')
if [ "$discovered" -lt "$MIN_REPOS" ]; then
  echo "ERROR: 'repo forall' listed only $discovered project(s); expected at least $MIN_REPOS." >&2
  echo "Refusing to report success — this looks like a partial failure, not a real shrink of the manifest." >&2
  exit 1
fi

# Bundles capture committed objects only. `repo` removing an obsolete project
# directory (as the migration in Task 6 does) takes a dirty worktree with it,
# and that migration is irreversible — so a dirty repository here is not
# something this script can silently accept. Checked as its own pass, before
# any bundle is written, so a refusal here never leaves a half-populated
# archive directory behind.
if [ "$ALLOW_DIRTY" != "1" ]; then
  dirty_repos=""
  while read -r path; do
    [ -d "$path/.git" ] || [ -f "$path/.git" ] || continue
    if ! porcelain=$(git -C "$path" status --porcelain 2>&1); then
      dirty_repos="${dirty_repos}${path} (status check failed: $porcelain)"$'\n'
      continue
    fi
    [ -n "$porcelain" ] && dirty_repos="${dirty_repos}${path}"$'\n'
  done < "$list_file"
  if [ -n "$dirty_repos" ]; then
    echo "ERROR: the following repositories have uncommitted or untracked changes:" >&2
    printf '%s' "$dirty_repos" >&2
    echo "Bundles capture committed objects only; proceeding would risk losing this work when 'repo' removes an obsolete project directory during the (irreversible) migration in Task 6." >&2
    echo "Set ALLOW_DIRTY=1 to proceed anyway, acknowledging that dirty work will not be archived." >&2
    exit 1
  fi
else
  echo "WARN: ALLOW_DIRTY=1 set; skipping the dirty-worktree check. Uncommitted or untracked work in any repository will NOT be captured by these bundles." >&2
fi

# Only now, after every validation check has passed, do we create the archive
# directory and truncate the manifest. Doing this earlier meant an aborted run
# left a zero-byte MANIFEST.txt beside bundles from a previous good run: the
# archive directory looked plausible while describing nothing, and Task 6's
# migration gate reads this file.
mkdir -p "$ARCHIVE_DIR"
: > "$MANIFEST"

meta_fail_count=0
bundle_fail_count=0
processed=0

# Reading from a file (not a pipe) keeps this loop in the current shell, so
# the counters above survive it and the exit-code checks after the loop see
# real totals.
while read -r path; do
  [ -d "$path/.git" ] || [ -f "$path/.git" ] || continue

  safe=$(printf '%s' "$path" | tr '/' '_')

  if ! branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>&1); then
    echo "ERROR: could not read HEAD branch for $path: $branch" >&2
    meta_fail_count=$((meta_fail_count + 1))
    continue
  fi
  if ! sha=$(git -C "$path" rev-parse HEAD 2>&1); then
    echo "ERROR: could not read HEAD sha for $path: $sha" >&2
    meta_fail_count=$((meta_fail_count + 1))
    continue
  fi
  # Commits reachable from any local ref but from no remote-tracking ref.
  if ! localonly=$(git -C "$path" rev-list --count --branches --not --remotes 2>&1); then
    echo "ERROR: could not count local-only commits for $path: $localonly" >&2
    meta_fail_count=$((meta_fail_count + 1))
    continue
  fi

  # Bundle first, so the manifest row's status column always reflects
  # whether a usable bundle actually exists for this repository.
  if git -C "$path" bundle create "$ARCHIVE_DIR/$safe.bundle" --all >/dev/null 2>&1; then
    bundle_status=ok
  else
    bundle_status=failed
    bundle_fail_count=$((bundle_fail_count + 1))
    echo "WARN: bundle failed for $path" >&2
  fi

  printf '%s|%s|%s|%s|%s\n' "$path" "$branch" "$sha" "$localonly" "$bundle_status" >> "$MANIFEST"
  processed=$((processed + 1))
done < "$list_file"

echo "Archived $processed of $discovered discovered repositories to $ARCHIVE_DIR"
echo "Repositories carrying local-only commits:"
awk -F'|' '$4 > 0 { printf "  %-52s %s commits (bundle: %s)\n", $1, $4, $5 }' "$MANIFEST"

if [ "$meta_fail_count" -gt 0 ] || [ "$bundle_fail_count" -gt 0 ]; then
  echo "ERROR: $meta_fail_count repositories could not be inspected and $bundle_fail_count bundle(s) failed to create; see WARN/ERROR lines above." >&2
  exit 1
fi
