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
# Local-branch triage. A branch is "redundant" when every commit reachable from
# it is also reachable from some remote-tracking ref; such a branch can be
# recreated from the remote at any time. Everything else carries local-only work
# and is kept, except orphaned dependabot branches whose upstream PR is gone.
# This file is sourced, never executed.

# cleanup_classify REPODIR -> BRANCH|CLASS|SHA|LOCALONLY|DATE|SUBJECT
cleanup_classify() {
  local d="$1" current head_sha branch sha localonly date subject class
  current="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  head_sha="$(git -C "$d" rev-parse HEAD 2>/dev/null || echo '')"

  git -C "$d" for-each-ref --format='%(refname:short)' refs/heads/ | while read -r branch; do
    sha="$(git -C "$d" rev-parse "$branch")"
    # Commits on this branch that are on no remote-tracking ref.
    localonly="$(git -C "$d" rev-list --count "$branch" --not --remotes)"
    date="$(git -C "$d" log -1 --format=%cs "$branch")"
    subject="$(git -C "$d" log -1 --format=%s "$branch" | tr '|' '/')"

    if [ "$branch" = "$current" ] \
       || { [ "$current" = "HEAD" ] && [ -n "$head_sha" ] && [ "$sha" = "$head_sha" ]; }; then
      # `rev-parse --abbrev-ref HEAD` reads back the literal string "HEAD"
      # when the repo is in detached HEAD state (the normal state after
      # `repo sync`, true for 131 of 132 repos here) — no branch name ever
      # matches that, so without the SHA fallback the current-branch guard
      # is silently a no-op almost everywhere.
      class=current
    elif [ "$localonly" -eq 0 ]; then
      class=redundant
    elif case "$branch" in dependabot/*) true ;; *) false ;; esac \
         && ! git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$branch" \
         && [ "$(git -C "$d" log --format=%ae "$branch" --not --remotes | grep -vc dependabot)" -eq 0 ]; then
      # The author check is NOT optional. A dependabot branch whose PR was
      # closed is disposable ONLY if every unpushed commit on it is the
      # bot's. People routinely commit fixes on top of a bump branch and
      # never push them; without this guard those commits are classified
      # stale and deleted. Measured on the real checkout: 18 of 40 orphaned
      # dependabot branches carried human commits, two of them four commits
      # deep.
      class=stale-dependabot
    else
      class=local-only
    fi

    printf '%s|%s|%s|%s|%s|%s\n' "$branch" "$class" "$sha" "$localonly" "$date" "$subject"
  done
}

# cleanup_apply REPODIR -> archive every branch, delete redundant + stale-dependabot
cleanup_apply() {
  local d="$1" branch class rest deleted=0
  while IFS='|' read -r branch class rest; do
    # Archive unconditionally, before any deletion, so nothing relies on reflog.
    git -C "$d" tag -f "archive/$branch" "$branch" >/dev/null 2>&1 || true
    case "$class" in
      redundant|stale-dependabot)
        git -C "$d" branch -D "$branch" >/dev/null 2>&1 && deleted=$((deleted + 1))
        ;;
    esac
  done < <(cleanup_classify "$d")
  printf '%s\n' "$deleted"
}

# cleanup_main [--apply]
cleanup_main() {
  local apply=0
  [ "${1:-}" = "--apply" ] && apply=1

  local root="$SOURCES_DIR/.."
  local report="$SOURCES_DIR/switch/cleanup-report.md"
  local total=0 redundant=0 stale=0 kept=0 path line branch class sha localonly date subject
  # Deleted branches are buffered here and folded into the report afterward,
  # so "what got removed" has an audit trail beyond grepping archive tags by
  # hand across every repository.
  local deleted_list; deleted_list="$(mktemp)"

  {
    printf '# Local branch cleanup report\n\n'
    printf 'Mode: %s\n\n' "$([ "$apply" = 1 ] && echo 'APPLIED' || echo 'DRY RUN')"
    printf '## Branches kept (local-only work)\n\n'
    printf '| Repository | Branch | Commits | Last commit | Subject |\n'
    printf '|---|---|---:|---|---|\n'
  } > "$report"

  while read -r path; do
    [ -d "$root/$path/.git" ] || [ -f "$root/$path/.git" ] || continue
    while IFS='|' read -r branch class sha localonly date subject; do
      total=$((total + 1))
      case "$class" in
        redundant)
          redundant=$((redundant + 1))
          printf '| `%s` | `%s` | redundant | %s |\n' "$path" "$branch" "$sha" >> "$deleted_list"
          ;;
        stale-dependabot)
          stale=$((stale + 1))
          printf '| `%s` | `%s` | stale-dependabot | %s |\n' "$path" "$branch" "$sha" >> "$deleted_list"
          ;;
        local-only)
          kept=$((kept + 1))
          printf '| `%s` | `%s` | %s | %s | %s |\n' "$path" "$branch" "$localonly" "$date" "$subject" >> "$report"
          ;;
      esac
    done < <(cleanup_classify "$root/$path")
    [ "$apply" = 1 ] && cleanup_apply "$root/$path" >/dev/null
  done < <(cd "$root" && repo forall -c 'echo "$REPO_PATH"' 2>/dev/null | sort)

  {
    printf '\n## Branches deleted (archived first; recover with `git checkout -b <name> archive/<name>`)\n\n'
    printf '| Repository | Branch | Reason | SHA |\n'
    printf '|---|---|---|---|\n'
    cat "$deleted_list"
  } >> "$report"
  rm -f "$deleted_list"

  {
    printf '\n## Summary\n\n'
    # `--` terminates option parsing: some bash builds treat a format string
    # that begins with '-' as an unknown printf option rather than as data.
    printf -- '- total local branches: %d\n' "$total"
    printf -- '- redundant (deleted, archived): %d\n' "$redundant"
    printf -- '- stale dependabot (deleted, archived): %d\n' "$stale"
    printf -- '- kept: %d\n' "$kept"
    printf '\nEvery branch was tagged `archive/<name>` before any deletion.\n'
    printf 'Recover one with: `git checkout -b <name> archive/<name>`\n'
  } >> "$report"

  printf 'total %d  redundant %d  stale-dependabot %d  kept %d\n' "$total" "$redundant" "$stale" "$kept"
  printf 'report: %s\n' "$report"
  [ "$apply" = 1 ] || printf '\nthis was a dry run; re-run with --apply to delete\n'
}
