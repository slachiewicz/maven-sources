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

run_all
