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

run_all
