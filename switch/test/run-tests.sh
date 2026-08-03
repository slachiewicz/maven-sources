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
# Plain-bash test runner. Each test is a function named test_*; the runner
# discovers and executes them, reporting pass/fail counts.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/../lib"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
TMP_ROOT=""

PASS=0
FAIL=0

setup_tmp() {
  TMP_ROOT="$(mktemp -d)"
}

teardown_tmp() {
  [ -n "$TMP_ROOT" ] && rm -rf "$TMP_ROOT"
  TMP_ROOT=""
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n  %s\n' "$CURRENT_TEST" "$1"
}

assert_eq() {
  local expected="$1" actual="$2" what="${3:-value}"
  if [ "$expected" = "$actual" ]; then
    return 0
  fi
  fail "$what: expected [$expected], got [$actual]"
}

assert_status() {
  local expected="$1" actual="$2" what="${3:-exit status}"
  assert_eq "$expected" "$actual" "$what"
}

assert_file_contains() {
  local file="$1" needle="$2"
  if grep -qF -- "$needle" "$file"; then
    return 0
  fi
  fail "expected $file to contain [$needle]"
}

assert_contains() {
  local haystack="$1" needle="$2" what="${3:-string}"
  case "$haystack" in
    *"$needle"*) return 0 ;;
  esac
  fail "expected $what to contain [$needle], got [$haystack]"
}

run_all() {
  local before
  for CURRENT_TEST in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
    before=$FAIL
    setup_tmp
    "$CURRENT_TEST"
    teardown_tmp
    if [ "$FAIL" -eq "$before" ]; then
      PASS=$((PASS + 1))
      printf 'ok   %s\n' "$CURRENT_TEST"
    fi
  done
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

. "$LIB_DIR/common.sh"

test_mode_runtime_reads_value() {
  cat > "$TMP_ROOT/x.mode" <<'EOF'
[runtime]
maven = 4.0.0-rc-5

[modules]
+ core-4
EOF
  assert_eq "4.0.0-rc-5" "$(mode_runtime "$TMP_ROOT/x.mode")" "runtime"
}

test_mode_modules_maps_signs_to_states() {
  cat > "$TMP_ROOT/y.mode" <<'EOF'
# a comment
[runtime]
maven = system

[modules]
+ ../../../core/maven-4.0.x
- ../../../core/maven

- 3.x
EOF
  local out
  out="$(mode_modules "$TMP_ROOT/y.mode")"
  assert_eq "on|../../../core/maven-4.0.x
off|../../../core/maven
off|3.x" "$out" "modules"
}

test_mode_modules_ignores_runtime_section() {
  cat > "$TMP_ROOT/z.mode" <<'EOF'
[runtime]
maven = 3.9.16
EOF
  assert_eq "" "$(mode_modules "$TMP_ROOT/z.mode")" "modules"
}

. "$LIB_DIR/aggregator.sh"

fixture() {
  cp "$TEST_DIR/fixtures/sample-pom.xml" "$TMP_ROOT/pom.xml"
  printf '%s\n' "$TMP_ROOT/pom.xml"
}

test_state_reads_active_module() {
  local p; p="$(fixture)"
  assert_eq "on" "$(agg_module_state "$p" '../../../core/maven')" "state"
}

test_state_reads_commented_module() {
  local p; p="$(fixture)"
  assert_eq "off" "$(agg_module_state "$p" '../../../core/maven-4.0.x')" "state"
}

test_state_rejects_unknown_module() {
  local p rc; p="$(fixture)"
  agg_module_state "$p" 'nope' >/dev/null 2>&1 && rc=0 || rc=$?
  assert_status 3 "$rc" "unknown module exit"
}

test_set_module_off_comments_it_out() {
  local p; p="$(fixture)"
  agg_set_module "$p" '../../../core/maven' off
  assert_file_contains "$p" '    <!--module>../../../core/maven</module-->'
  assert_eq "off" "$(agg_module_state "$p" '../../../core/maven')" "state after off"
}

test_set_module_on_uncomments_it() {
  local p; p="$(fixture)"
  agg_set_module "$p" '../../../core/maven-4.0.x' on
  assert_file_contains "$p" '    <module>../../../core/maven-4.0.x</module>'
}

test_set_module_preserves_indentation() {
  local p; p="$(fixture)"
  agg_set_module "$p" '3.x' on
  assert_file_contains "$p" '    <module>3.x</module>'
}

test_set_module_is_idempotent() {
  local p before after; p="$(fixture)"
  agg_set_module "$p" '../../../core/maven' off
  before="$(cat "$p")"
  agg_set_module "$p" '../../../core/maven' off
  after="$(cat "$p")"
  assert_eq "$before" "$after" "second off write"
}

test_round_trip_restores_file_exactly() {
  local p original; p="$(fixture)"
  original="$(cat "$p")"
  agg_set_module "$p" '../../../core/maven' off
  agg_set_module "$p" '../../../core/maven' on
  assert_eq "$original" "$(cat "$p")" "round trip"
}

test_prose_comment_is_not_a_candidate() {
  local p rc; p="$(fixture)"
  agg_module_state "$p" '../../../misc/plugin-testing' >/dev/null 2>&1 && rc=0 || rc=$?
  assert_status 3 "$rc" "prose comment exit"
}

test_fully_bracketed_comment_is_not_a_candidate() {
  local p rc; p="$(fixture)"
  agg_module_state "$p" '../../../svn/repository-tools' >/dev/null 2>&1 && rc=0 || rc=$?
  assert_status 3 "$rc" "bracketed comment exit"
}

test_find_pom_locates_declaring_file() {
  local p; p="$(fixture)"
  assert_eq "$p" "$(agg_find_pom "$TMP_ROOT" '../../../core/maven')" "found pom"
}

test_find_pom_exits_3_when_absent() {
  local rc; fixture >/dev/null
  agg_find_pom "$TMP_ROOT" 'no-such-module' >/dev/null 2>&1 && rc=0 || rc=$?
  assert_status 3 "$rc" "absent module exit"
}

test_find_pom_exits_4_when_ambiguous() {
  local rc; fixture >/dev/null
  mkdir -p "$TMP_ROOT/second"
  cp "$TEST_DIR/fixtures/sample-pom.xml" "$TMP_ROOT/second/pom.xml"
  agg_find_pom "$TMP_ROOT" '../../../core/maven' >/dev/null 2>&1 && rc=0 || rc=$?
  assert_status 4 "$rc" "ambiguous module exit"
}

test_set_module_aborts_without_writing_when_awk_fails() {
  local p original rc; p="$(fixture)"
  original="$(cat "$p")"
  # Shadow awk with a stub that fails ONLY the rewrite invocation, emitting a
  # partial file first. It must delegate every other awk call to the real
  # binary: a stub that fails indiscriminately also intercepts
  # agg_module_state's internal awk, so the function would abort on the
  # pre-existing exit-3 path and the test would pass against vulnerable code
  # too. The rewrite call is the only one passing a `want=` variable.
  mkdir -p "$TMP_ROOT/bin"
  cat > "$TMP_ROOT/bin/awk" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    want=*)
      for last in "$@"; do :; done   # last argument is the POM path
      head -2 "$last"                # emit a truncated file, then fail
      exit 5
      ;;
  esac
done
exec /usr/bin/awk "$@"
STUB
  chmod +x "$TMP_ROOT/bin/awk"
  ( PATH="$TMP_ROOT/bin:$PATH"; agg_set_module "$p" '../../../core/maven' off ) >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "$original" "$(cat "$p")" "POM must be unmodified after awk failure"
  [ "$rc" -ne 0 ] || fail "agg_set_module must exit non-zero when awk fails"
}

test_set_module_leaves_no_temp_files_behind() {
  local p; p="$(fixture)"
  agg_set_module "$p" '../../../core/maven' off
  assert_eq "" "$(find "$TMP_ROOT" -name 'pom.xml.*' -print)" "leftover temp files"
}

test_set_module_leaves_other_lines_untouched() {
  local p; p="$(fixture)"
  agg_set_module "$p" '../../../core/maven' off
  assert_file_contains "$p" '    <module>../../../core/build-cache</module>'
  assert_file_contains "$p" '    <module>../../../core/wrapper</module>'
  assert_file_contains "$p" '    <!--<module>../../../svn/repository-tools</module>-->'
}

# --- C1 regression: a trailing comment on a [section] header must not fold
# into the section name and swallow the whole section. This is exactly the
# form DESIGN.md documented before the fix: "[modules]   # + activate, ...".
test_mode_header_trailing_comment_still_parses_modules() {
  cat > "$TMP_ROOT/c1.mode" <<'EOF'
[runtime]
maven = 4.0.0-rc-5

[modules]                # + activate, - comment out
+ core-4
- 3.x
EOF
  assert_eq "on|core-4
off|3.x" "$(mode_modules "$TMP_ROOT/c1.mode")" "modules with trailing comment header"
}

test_runtime_header_trailing_comment_still_parses_runtime() {
  cat > "$TMP_ROOT/c1r.mode" <<'EOF'
[runtime]  # comment
maven = 4.0.0-rc-5

[modules]
+ core-4
EOF
  assert_eq "4.0.0-rc-5" "$(mode_runtime "$TMP_ROOT/c1r.mode")" "runtime with trailing comment header"
}

# --- CRLF mode files (e.g. checked out or edited on Windows) must parse
# identically to LF ones.
test_crlf_mode_file_parses() {
  printf '[runtime]\r\nmaven = 4.0.0-rc-5\r\n\r\n[modules]\r\n+ core-4\r\n- 3.x\r\n' \
    > "$TMP_ROOT/crlf.mode"
  assert_eq "4.0.0-rc-5" "$(mode_runtime "$TMP_ROOT/crlf.mode")" "runtime crlf"
  assert_eq "on|core-4
off|3.x" "$(mode_modules "$TMP_ROOT/crlf.mode")" "modules crlf"
}

# --- toolchain_current under the caller's real `set -euo pipefail`, in the
# three states that matter: unset, resolvable, and dangling. Run in a
# sub-bash against a throwaway copy of the libraries so a leaked `cd` or an
# `exit` cannot affect the test runner itself. SOURCES_DIR is derived from
# BASH_SOURCE inside common.sh, so the libraries must be copied into a real
# temporary tree rather than sourced in place with a faked variable.
test_toolchain_current_survives_set_euo_pipefail() {
  local tree="$TMP_ROOT/tc-tree"
  mkdir -p "$tree/switch/lib"
  cp "$LIB_DIR/common.sh" "$tree/switch/lib/common.sh"
  cp "$LIB_DIR/toolchain.sh" "$tree/switch/lib/toolchain.sh"
  cp "$LIB_DIR/aggregator.sh" "$tree/switch/lib/aggregator.sh"

  local out rc

  # 1. no `current` symlink at all. Uses the SAME call shape as cmd_status
  # (`home="$(toolchain_current)"`, a bare assignment) rather than passing the
  # substitution as a printf argument: under `set -e`, bash propagates a
  # command substitution's failure through a plain assignment statement, but
  # NOT through a substitution embedded in another command's argument list —
  # `printf "%s" "$(false)"` does not abort, `x="$(false)"` does. The real bug
  # only shows up in the assignment form, so the test must use it too.
  out="$(bash -c '
    set -euo pipefail
    . "$1/switch/lib/common.sh"
    . "$1/switch/lib/toolchain.sh"
    home="$(toolchain_current)"
    printf "[%s]" "$home"
  ' _ "$tree" 2>&1)" && rc=0 || rc=$?
  assert_status 0 "$rc" "no-symlink case must not abort the caller"
  assert_eq "[]" "$out" "no-symlink case yields empty"

  # 2. a good symlink.
  mkdir -p "$tree/toolchain/apache-maven-x"
  ln -s apache-maven-x "$tree/toolchain/current"
  out="$(bash -c '
    set -euo pipefail
    . "$1/switch/lib/common.sh"
    . "$1/switch/lib/toolchain.sh"
    toolchain_current
  ' _ "$tree" 2>&1)" && rc=0 || rc=$?
  assert_status 0 "$rc" "good-symlink case must not abort the caller"
  # Compare against the physically resolved path too: on macOS $TMP_ROOT
  # itself typically lives under /var, which is a symlink to /private/var, and
  # `cd -P` inside toolchain_current resolves that as well.
  local expected; expected="$(cd -P "$tree/toolchain/apache-maven-x" && pwd)"
  assert_eq "$expected" "$out" "good-symlink case resolves"

  # 3. a DANGLING symlink: passes -L, fails the cd. This is the case I2 fixed.
  # Again use the bare-assignment call shape — this is the one that actually
  # exercises the bug under `set -e`.
  rm -f "$tree/toolchain/current"
  ln -s apache-maven-does-not-exist "$tree/toolchain/current"
  out="$(bash -c '
    set -euo pipefail
    . "$1/switch/lib/common.sh"
    . "$1/switch/lib/toolchain.sh"
    home="$(toolchain_current)"
    printf "[%s]" "$home"
  ' _ "$tree" 2>&1)" && rc=0 || rc=$?
  assert_status 0 "$rc" "dangling-symlink case must not abort the caller"
  assert_eq "[]" "$out" "dangling-symlink case yields empty"
}

# --- End-to-end fixture tree for the tests below: a throwaway copy of the
# libraries, the entry point, and a fixture aggregator POM, wired together
# exactly as the real checkout is (mvn-switch sources switch/lib/*.sh
# relative to its own location; common.sh derives SOURCES_DIR the same way).
make_e2e_tree() {
  local tree="$TMP_ROOT/e2e-tree"
  mkdir -p "$tree/switch/lib" "$tree/switch/modes" "$tree/aggregator"
  cp "$LIB_DIR/common.sh"     "$tree/switch/lib/common.sh"
  cp "$LIB_DIR/aggregator.sh" "$tree/switch/lib/aggregator.sh"
  cp "$LIB_DIR/toolchain.sh"  "$tree/switch/lib/toolchain.sh"
  cp "$ROOT_DIR/mvn-switch"   "$tree/mvn-switch"
  chmod +x "$tree/mvn-switch"
  cp "$TEST_DIR/fixtures/sample-pom.xml" "$tree/aggregator/pom.xml"
  printf '%s\n' "$tree"
}

test_dry_run_end_to_end_writes_nothing() {
  local tree; tree="$(make_e2e_tree)"

  # Stub `mvn -v` so this test does not depend on a Maven being installed on
  # the machine running it. cmd_apply's dry-run path still calls
  # toolchain_maven_home for a `system` runtime, to report which home it
  # would activate.
  mkdir -p "$tree/stubbin"
  cat > "$tree/stubbin/mvn" <<'STUB'
#!/bin/sh
if [ "$1" = "-v" ]; then
  echo "Apache Maven 3.9.16 (stub)"
  echo "Maven home: /stub/maven-home"
  exit 0
fi
exit 1
STUB
  chmod +x "$tree/stubbin/mvn"

  cat > "$tree/switch/modes/e2e.mode" <<'EOF'
[runtime]
maven = system

[modules]
+ ../../../core/maven-4.0.x
- ../../../core/maven
EOF

  local before after out rc
  before="$(cat "$tree/aggregator/pom.xml")"
  out="$(PATH="$tree/stubbin:$PATH" "$tree/mvn-switch" e2e --dry-run 2>&1)" && rc=0 || rc=$?
  after="$(cat "$tree/aggregator/pom.xml")"

  assert_status 0 "$rc" "dry-run exit status"
  assert_eq "$before" "$after" "dry-run must not modify the aggregator POM"
  [ -f "$tree/.switch-state" ] && fail "dry-run must not write .switch-state"
  assert_contains "$out" "would set" "dry-run output"
  assert_contains "$out" "maven-4.0.x" "dry-run output"
}

# --- I5 / cmd_apply zero-module guard: a mode file whose [modules] section
# resolves to nothing must be refused, not silently applied as a no-op.
test_zero_module_mode_is_refused_by_cmd_apply() {
  local tree; tree="$(make_e2e_tree)"

  cat > "$tree/switch/modes/empty.mode" <<'EOF'
[runtime]
maven = system

[modules]
EOF

  local before after out rc
  before="$(cat "$tree/aggregator/pom.xml")"
  out="$("$tree/mvn-switch" empty 2>&1)" && rc=0 || rc=$?
  after="$(cat "$tree/aggregator/pom.xml")"

  [ "$rc" -ne 0 ] || fail "mvn-switch must exit non-zero for a zero-module mode"
  assert_eq "$before" "$after" "zero-module mode must not modify the aggregator POM"
  [ -f "$tree/.switch-state" ] && fail "zero-module mode must not write .switch-state"
  assert_contains "$out" "resolved to no modules" "zero-module error message"
}

# --- I4: agg_set_module must preserve the POM's file mode. mktemp creates its
# temp file at 0600, and `mv` carries that mode onto the target, so without
# the fix a switch silently resets every touched POM from 644 to 600. Git
# tracks only the exec bit, so content-only assertions (the pre-existing
# tests above) cannot catch this — it needs its own direct check of the mode
# bits, read the BSD way since `stat --format` is GNU-only.
test_set_module_preserves_file_mode() {
  local p; p="$(fixture)"
  chmod 644 "$p"
  local before; before="$(stat -f %Lp "$p")"
  assert_eq "644" "$before" "fixture must start at mode 644"

  agg_set_module "$p" '../../../core/maven' off

  local after; after="$(stat -f %Lp "$p")"
  assert_eq "644" "$after" "POM mode after agg_set_module"
}

. "$LIB_DIR/cleanup.sh"

# Build a throwaway repo with a fake "remote" so classification has something real to read.
make_repo() {
  local d="$TMP_ROOT/repo" up="$TMP_ROOT/upstream"
  git init -q --bare "$up"
  git init -q -b master "$d"
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name Test
  git -C "$d" commit -q --allow-empty -m base
  git -C "$d" remote add origin "$up"
  git -C "$d" push -q origin master
  git -C "$d" fetch -q origin

  # redundant: points at a commit already on the remote
  git -C "$d" branch redundant master

  # local-only: a commit that was never pushed
  git -C "$d" checkout -q -b keep-me master
  git -C "$d" commit -q --allow-empty -m "unpushed work"

  # stale dependabot: bot-only commit, and no origin/<same name>
  git -C "$d" checkout -q -b dependabot/maven/foo-1.0 master
  git -C "$d" -c user.email="dependabot[bot]@users.noreply.github.com" \
              -c user.name="dependabot[bot]" \
              commit -q --allow-empty -m "bump foo"

  git -C "$d" checkout -q master
  printf '%s\n' "$d"
}

# Same shape as make_repo's dependabot branch, but with a human commit on top
# of the bot's — the case that must NOT be deleted. People routinely commit
# fixes on a bump branch and never push them; the branch is disposable only
# when every unpushed commit is the bot's.
make_repo_dependabot_with_human_commit() {
  local d="$TMP_ROOT/repo-mixed" up="$TMP_ROOT/upstream-mixed"
  git init -q --bare "$up"
  git init -q -b master "$d"
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name Test
  git -C "$d" commit -q --allow-empty -m base
  git -C "$d" remote add origin "$up"
  git -C "$d" push -q origin master
  git -C "$d" fetch -q origin

  # no origin/<same name>, so this is orphaned like any stale dependabot branch
  git -C "$d" checkout -q -b dependabot/maven/bar-2.0 master
  git -C "$d" -c user.email="dependabot[bot]@users.noreply.github.com" \
              -c user.name="dependabot[bot]" \
              commit -q --allow-empty -m "bump bar"
  # a human commit on top, never pushed
  git -C "$d" -c user.email="human@example.com" \
              -c user.name="Human" \
              commit -q --allow-empty -m "Fix #322: manual follow-up on the bump"

  git -C "$d" checkout -q master
  printf '%s\n' "$d"
}

test_classify_marks_pushed_branch_redundant() {
  local d; d="$(make_repo)"
  assert_eq "redundant" "$(cleanup_classify "$d" | awk -F'|' '$1 == "redundant" { print $2 }')" "class"
}

test_classify_protects_unpushed_branch() {
  local d; d="$(make_repo)"
  assert_eq "local-only" "$(cleanup_classify "$d" | awk -F'|' '$1 == "keep-me" { print $2 }')" "class"
}

test_classify_marks_orphaned_dependabot_stale() {
  local d; d="$(make_repo)"
  assert_eq "stale-dependabot" "$(cleanup_classify "$d" | awk -F'|' '$1 ~ /^dependabot/ { print $2 }')" "class"
}

# Discriminating: this must FAIL against the pre-fix classifier (commit
# 97a8508), which deletes any orphaned dependabot/* branch regardless of what
# is committed on it, and PASS after the author-only guard is added.
test_classify_protects_dependabot_branch_with_human_commit() {
  local d; d="$(make_repo_dependabot_with_human_commit)"
  assert_eq "local-only" "$(cleanup_classify "$d" | awk -F'|' '$1 ~ /^dependabot/ { print $2 }')" "class"
}

test_classify_never_touches_current_branch() {
  local d; d="$(make_repo)"
  assert_eq "current" "$(cleanup_classify "$d" | awk -F'|' '$1 == "master" { print $2 }')" "class"
}

test_apply_archives_before_deleting() {
  local d; d="$(make_repo)"
  cleanup_apply "$d" >/dev/null
  # redundant is gone as a branch...
  assert_eq "" "$(git -C "$d" branch --list redundant)" "redundant branch"
  # ...but recoverable from its archive tag
  assert_eq "refs/tags/archive/redundant" \
    "$(git -C "$d" rev-parse --symbolic-full-name refs/tags/archive/redundant)" "archive tag"
  # and local-only work survives untouched
  assert_eq "  keep-me" "$(git -C "$d" branch --list keep-me)" "kept branch"
}

run_all
