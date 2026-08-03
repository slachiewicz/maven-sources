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

mkdir -p "$ARCHIVE_DIR"
: > "$MANIFEST"

cd "$CHECKOUT_ROOT"

# `repo forall` sets REPO_PATH for each project. Print it one per line so the
# outer loop can bundle each repository with plain git.
repo forall -c 'echo "$REPO_PATH"' 2>/dev/null | sort | while read -r path; do
  [ -d "$path/.git" ] || [ -f "$path/.git" ] || continue

  safe=$(printf '%s' "$path" | tr '/' '_')
  branch=$(git -C "$path" rev-parse --abbrev-ref HEAD)
  sha=$(git -C "$path" rev-parse HEAD)
  # Commits reachable from any local ref but from no remote-tracking ref.
  localonly=$(git -C "$path" rev-list --count --branches --not --remotes)

  printf '%s|%s|%s|%s\n' "$path" "$branch" "$sha" "$localonly" >> "$MANIFEST"

  git -C "$path" bundle create "$ARCHIVE_DIR/$safe.bundle" --all >/dev/null 2>&1 \
    || echo "WARN: bundle failed for $path" >&2
done

echo "Archived $(wc -l < "$MANIFEST" | tr -d ' ') repositories to $ARCHIVE_DIR"
echo "Repositories carrying local-only commits:"
awk -F'|' '$4 > 0 { printf "  %-52s %s commits\n", $1, $4 }' "$MANIFEST"
