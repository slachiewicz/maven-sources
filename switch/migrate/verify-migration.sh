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
# Assert that the checkout matches the master manifest, that the 3.x and
# Maven 4 lines are genuinely distinct on disk, and that nothing which carried
# local-only work vanished without a recoverable bundle.

set -euo pipefail

CHECKOUT_ROOT="${CHECKOUT_ROOT:-$HOME/mvn4}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$HOME/mvn4-archive}"
rc=0

cd "$CHECKOUT_ROOT"

echo "== project paths required by the master manifest =="
for p in \
  core/maven core/maven-4.0.x core/3.x/maven-3 core/3.x/mvnd-1 core/3.x/its-3 \
  plugins/core-4/maven-clean-plugin plugins/core-4/maven-compiler-plugin \
  plugins/core-4/maven-deploy-plugin plugins/core-4/maven-install-plugin \
  plugins/core-4/maven-resources-plugin \
  plugins/packaging-4/maven-jar-plugin plugins/packaging-4/maven-source-plugin \
  shared-4/archiver shared-4/filtering \
  misc/gh-actions-shared/main misc/gh-actions-shared/v4
do
  if [ -d "$p/.git" ] || [ -f "$p/.git" ]; then
    printf '  ok      %s\n' "$p"
  else
    printf '  MISSING %s\n' "$p"; rc=1
  fi
done

echo
echo "== the core lines must be genuinely distinct =="
# Reads the project's own <version>, i.e. the first one after </parent>.
project_version() {
  awk '/<\/parent>/ { p = 1 } p && /<version>/ { gsub(/.*<version>|<\/version>.*/, ""); print; exit }' "$1/pom.xml"
}
check_version() {
  local path="$1" want="$2" got
  got="$(project_version "$path")"
  if [ "$got" = "$want" ]; then
    printf '  ok      %-22s %s\n' "$path" "$got"
  else
    printf '  WRONG   %-22s got %s want %s\n' "$path" "$got" "$want"; rc=1
  fi
}
check_version core/maven         4.1.0-SNAPSHOT
check_version core/maven-4.0.x   4.0.0-SNAPSHOT
check_version core/3.x/maven-3   3.10.0-SNAPSHOT

echo
echo "== the plugin/shared lines must be genuinely distinct =="
# The 3.x directory and its -4 twin are the SAME repository on different
# branches. If these ever report the same mavenVersion, the manifest revision
# pinning has silently stopped working and every mode would build one line.
maven_version() { grep -m1 -oE '<mavenVersion>[^<]*' "$1/pom.xml" | cut -d'>' -f2; }
check_pair() {
  local three="$1" four="$2" v3 v4
  v3="$(maven_version "$three")"
  v4="$(maven_version "$four")"
  case "$v3" in 3.*) ;; *) printf '  WRONG   %-42s mavenVersion=%s (expected 3.x)\n' "$three" "$v3"; rc=1; return ;; esac
  case "$v4" in 4.*) ;; *) printf '  WRONG   %-42s mavenVersion=%s (expected 4.x)\n' "$four" "$v4"; rc=1; return ;; esac
  printf '  ok      %-42s %s  vs  %s\n' "${three##*/}" "$v3" "$v4"
}
check_pair plugins/core/maven-clean-plugin      plugins/core-4/maven-clean-plugin
check_pair plugins/core/maven-compiler-plugin   plugins/core-4/maven-compiler-plugin
check_pair plugins/core/maven-deploy-plugin     plugins/core-4/maven-deploy-plugin
check_pair plugins/core/maven-install-plugin    plugins/core-4/maven-install-plugin
check_pair plugins/core/maven-resources-plugin  plugins/core-4/maven-resources-plugin
check_pair plugins/packaging/maven-jar-plugin   plugins/packaging-4/maven-jar-plugin
check_pair plugins/packaging/maven-source-plugin plugins/packaging-4/maven-source-plugin
check_pair shared/archiver                      shared-4/archiver
check_pair shared/filtering                     shared-4/filtering

echo
echo "== every repository that held local-only commits is still restorable =="
missing_bundle=0
while IFS='|' read -r path _branch _sha localonly _status; do
  [ "${localonly:-0}" -gt 0 ] 2>/dev/null || continue
  safe="$(printf '%s' "$path" | tr '/' '_')"
  if [ -f "$ARCHIVE_DIR/$safe.bundle" ]; then
    printf '  ok        %s\n' "$path"
  else
    printf '  NO BUNDLE %s\n' "$path"; missing_bundle=$((missing_bundle + 1)); rc=1
  fi
done < "$ARCHIVE_DIR/MANIFEST.txt"
[ "$missing_bundle" -eq 0 ] && echo "  (all local-only work accounted for)"

echo
echo "== no repository left in a conflicted or mid-rebase state =="
# `git rev-parse --git-dir` returns a path RELATIVE to the repository, so it
# must be resolved with --absolute-git-dir before testing for rebase markers
# from anywhere else. Getting this wrong reports a clean tree that is not.
stuck=0
while read -r path; do
  [ -d "$path/.git" ] || [ -f "$path/.git" ] || continue
  gd="$(git -C "$path" rev-parse --absolute-git-dir)"
  if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
    printf '  MID-REBASE %s\n' "$path"; stuck=$((stuck + 1)); rc=1
  fi
  if git -C "$path" status --porcelain 2>/dev/null | grep -qE '^(UU|AA|DD|AU|UA|DU|UD)'; then
    printf '  CONFLICTED %s\n' "$path"; stuck=$((stuck + 1)); rc=1
  fi
done < <(repo forall -c 'echo "$REPO_PATH"' 2>/dev/null | sort)
[ "$stuck" -eq 0 ] && echo "  (none)"

echo
if [ "$rc" -eq 0 ]; then
  echo "migration verified"
else
  echo "MIGRATION VERIFICATION FAILED"
fi
exit $rc
