# Maven build-mode switcher — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give this `repo`-tool Maven checkout a `./mvn-switch <mode>` command that selects between three build configurations (`mvn3`, `mvn4`, `mvn4-3xplugins`) so that `cd sources/aggregator && mvn install -DskipTests` builds the tree in each.

**Architecture:** Migrate `.repo` from the abandoned `default` manifest branch to the maintained `master` branch, which already checks out the 3.x and 4.x lines into separate directories. Mode switching then reduces to toggling `<module>` entries in `sources/aggregator/**/pom.xml` between `<module>X</module>` and `<!--module>X</module-->`, plus re-pointing a `toolchain/current` symlink at the right Maven distribution. No git branch is ever moved.

**Tech Stack:** Bash 4+, `awk`, `sed`, `git`, `curl`, `tar`, `shasum`. No Maven plugin, no XML parser, no test framework — tests are plain bash over fixture POMs.

## Global Constraints

- Read `sources/switch/DESIGN.md` before starting. It is the spec; this plan implements it.
- Repository root is `/Users/slachiewicz/mvn4`. All new files live under `/Users/slachiewicz/mvn4/sources/`.
- Every shell script starts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- **macOS / BSD userland.** `sed -i` requires a backup-suffix argument and GNU-only expressions are unavailable. Prefer `awk` writing to a temp file followed by `mv`. Never call `sed -i` without an explicit `''` argument.
- Bash 4+ is required (the shell is 5.3). Scripts must still avoid associative arrays — use plain text plus `grep`/`awk` — so the code stays readable and portable.
- Allowed external commands: `git`, `curl`, `tar`, `shasum`, `awk`, `sed`, `grep`, `mkdir`, `ln`, `mv`, `rm`. Nothing else.
- Every new `.sh` and `pom.xml` file carries the ASF Apache-2.0 licence header verbatim as it appears in `sources/aggregator/pom.xml`. Apache RAT will fail the build otherwise.
- The switcher must **never** edit a POM outside `sources/aggregator/`, and **never** run `git switch`, `git checkout`, `git branch -D` or `git reset` outside the `cleanup` subcommand.
- Maven 4 version is exactly `4.0.0-rc-5`. Its `bin.tar.gz` SHA-512 is
  `942c19fb75ab7a5d2a11001e3d6c8c6214c81d2736ebc613243d22f7b4ab0404092d47511317d767e8f22a1c634a3762cc7e6b4b6693580ac86e73c0bed1bee2`.
  Maven 4.0.0 GA does not exist; do not look for it.
- The three mode names are exactly `mvn3`, `mvn4`, `mvn4-3xplugins`.
- Commit after every task, to the `sources` repository only.

---

## File structure

| File | Responsibility |
|---|---|
| `sources/mvn-switch` | Entry point. Argument parsing, subcommand dispatch, summary output. Nothing else. |
| `sources/switch/lib/common.sh` | Logging, path constants, mode-file parsing. No knowledge of POMs or Maven. |
| `sources/switch/lib/aggregator.sh` | Reading and flipping `<module>` lines. No knowledge of modes or runtimes. |
| `sources/switch/lib/toolchain.sh` | Downloading, verifying and selecting a Maven distribution. |
| `sources/switch/lib/cleanup.sh` | Local-branch classification, archiving and deletion. |
| `sources/switch/modes/*.mode` | Data. One complete module state description per mode. |
| `sources/switch/migrate/archive-all.sh` | One-shot pre-migration safety net. |
| `sources/switch/migrate/verify-migration.sh` | One-shot post-migration assertion. |
| `sources/switch/test/run-tests.sh` | Plain-bash test runner over fixtures. |
| `sources/switch/test/fixtures/` | Small POMs exercising the toggler. |
| `sources/aggregator/core/3.x/pom.xml` | New aggregator tree for the Maven 3.10 line. |
| `sources/aggregator/plugins/core-4/pom.xml` | New aggregator tree for 4-native core plugins. |
| `sources/aggregator/plugins/packaging-4/pom.xml` | New aggregator tree for 4-native packaging plugins. |
| `sources/aggregator/shared-4/pom.xml` | New aggregator tree for 4-native shared components. |

---

### Task 1: Pre-migration safety net

Bundles every repository's full ref set outside the checkout, so the manifest migration in Task 6 cannot destroy work. Must land before anything touches `.repo`.

**Files:**
- Create: `sources/switch/migrate/archive-all.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `~/mvn4-archive/<sanitised-path>.bundle` per repository, plus `~/mvn4-archive/MANIFEST.txt` listing `<repo path>|<branch>|<sha>|<local-only-commit-count>`.

- [ ] **Step 1: Write the script**

```bash
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

# NOTE: the shipped switch/migrate/archive-all.sh SUPERSEDES this block. It was
# hardened after review to capture `repo forall`'s real exit status, reject
# empty output, enforce a MIN_REPOS floor, record a bundle-status column, and
# exit non-zero if any bundle or metadata read failed. Treat the shipped file
# as authoritative; two further fixes are required there before Task 6:
#   1. Create ARCHIVE_DIR and truncate MANIFEST only AFTER the validation
#      checks pass. Truncating first leaves a zero-byte manifest beside stale
#      bundles from a previous good run, so the archive directory looks
#      plausible while describing nothing — and Task 6's gate reads that file.
#   2. Refuse to proceed if any repository has uncommitted or untracked work.
#      Bundles capture committed objects only, and `repo` removing an obsolete
#      project directory takes a dirty worktree with it. Task 6 is irreversible.

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
```

- [ ] **Step 2: Make it executable and run it**

```bash
chmod +x /Users/slachiewicz/mvn4/sources/switch/migrate/archive-all.sh
/Users/slachiewicz/mvn4/sources/switch/migrate/archive-all.sh
```

Expected: `Archived 128 repositories to /Users/slachiewicz/mvn4-archive`, followed by a list that includes `core/maven-3`, `misc/gh-actions-shared`, `plexus/components/cipher`, `plexus/plexus-containers` and `shared/artifact-transfer`.

- [ ] **Step 3: Verify a bundle is actually restorable**

Pick the highest-risk repository and prove the archive works before trusting it.

Use `--mirror`. A plain `git clone` of a bundle remaps every non-default branch to `refs/remotes/origin/*`, so `refs/heads/<branch>` would appear missing even from a perfectly good bundle — the clone semantics would be under test, not the archive.

```bash
cd /tmp && rm -rf bundle-check && \
git clone --mirror ~/mvn4-archive/core_maven-3.bundle bundle-check 2>&1 | tail -2 && \
git -C bundle-check for-each-ref --format='%(refname)' refs/heads/ | wc -l && \
git -C bundle-check rev-parse refs/heads/copilot/mng-11011-settings-interpolation && \
git -C /Users/slachiewicz/mvn4/core/maven-3 rev-parse copilot/mng-11011-settings-interpolation
```

Expected: the clone succeeds, the local-branch count is greater than 5, and the last two commands print **the same SHA** — proving the bundle holds the live checkout's local-only work under its original ref name. If they differ or either fails, **stop** — do not proceed to Task 6.

- [ ] **Step 4: Commit**

```bash
cd /Users/slachiewicz/mvn4/sources
git add switch/migrate/archive-all.sh
git commit -m "switch: add pre-migration repository archiver"
```

---

### Task 2: Test harness and mode-file parser

**Files:**
- Create: `sources/switch/test/run-tests.sh`
- Create: `sources/switch/lib/common.sh`

**Interfaces:**
- Consumes: nothing.
- Produces, all sourced by later tasks from `lib/common.sh`:
  - `SOURCES_DIR` — absolute path to `sources/`.
  - `AGGREGATOR_DIR` — absolute path to `sources/aggregator`.
  - `log_info MSG`, `log_warn MSG`, `log_error MSG` — write to stderr with a level prefix.
  - `die MSG` — `log_error` then `exit 1`.
  - `mode_path MODE` — prints `sources/switch/modes/MODE.mode`; `die`s if absent.
  - `mode_runtime MODEFILE` — prints the `[runtime] maven` value.
  - `mode_modules MODEFILE` — prints one `on|PATH` or `off|PATH` line per `[modules]` entry, in file order.

- [ ] **Step 1: Write the test runner**

The runner is a dependency of every later test step, so it comes first.

```bash
#!/usr/bin/env bash
# <ASF licence header — copy verbatim from Task 1>
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
```

- [ ] **Step 2: Write the failing test for the mode parser**

Append to `run-tests.sh`, above a final `run_all` call:

```bash
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
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
chmod +x /Users/slachiewicz/mvn4/sources/switch/test/run-tests.sh
/Users/slachiewicz/mvn4/sources/switch/test/run-tests.sh
```

Expected: failure, because `lib/common.sh` does not exist — `run-tests.sh: line N: .../lib/common.sh: No such file or directory`.

- [ ] **Step 4: Write `lib/common.sh`**

```bash
#!/usr/bin/env bash
# <ASF licence header — copy verbatim from Task 1>
#
# Shared helpers: logging, paths, mode-file parsing.
# This file is sourced, never executed.

COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$(cd "$COMMON_SH_DIR/../.." && pwd)"
AGGREGATOR_DIR="$SOURCES_DIR/aggregator"
MODES_DIR="$SOURCES_DIR/switch/modes"

log_info()  { printf 'INFO  %s\n'  "$1" >&2; }
log_warn()  { printf 'WARN  %s\n'  "$1" >&2; }
log_error() { printf 'ERROR %s\n'  "$1" >&2; }
die()       { log_error "$1"; exit 1; }

# mode_path MODE -> absolute path of the mode file
mode_path() {
  local mode="$1" path="$MODES_DIR/$1.mode"
  [ -f "$path" ] || die "unknown mode '$mode'; available: $(ls "$MODES_DIR" 2>/dev/null | sed 's/\.mode$//' | tr '\n' ' ')"
  printf '%s\n' "$path"
}

# mode_runtime MODEFILE -> the [runtime] maven value
mode_runtime() {
  awk '
    { sub(/\r$/, "") }                      # tolerate CRLF mode files
    /^[ \t]*\[/ {
      # Take ONLY the bracketed name. Stripping brackets from the whole line
      # folds a trailing comment into the section name, so `[modules]  # note`
      # becomes "modules#note" and every module line is skipped — a mode that
      # silently switches nothing while status reports a clean match.
      section = $0
      sub(/^[ \t]*\[/, "", section)
      sub(/\].*$/, "", section)
      gsub(/[ \t]/, "", section)
      next
    }
    section == "runtime" && /^[ \t]*maven[ \t]*=/ {
      sub(/^[^=]*=[ \t]*/, "")
      sub(/[ \t]+$/, "")
      print
      exit
    }
  ' "$1"
}

# mode_modules MODEFILE -> "on|PATH" / "off|PATH" lines, in file order
mode_modules() {
  awk '
    /^[ \t]*#/  { next }
    /^[ \t]*$/  { next }
    { sub(/\r$/, "") }                      # tolerate CRLF mode files
    /^[ \t]*\[/ {
      # Take ONLY the bracketed name. Stripping brackets from the whole line
      # folds a trailing comment into the section name, so `[modules]  # note`
      # becomes "modules#note" and every module line is skipped — a mode that
      # silently switches nothing while status reports a clean match.
      section = $0
      sub(/^[ \t]*\[/, "", section)
      sub(/\].*$/, "", section)
      gsub(/[ \t]/, "", section)
      next
    }
    section != "modules" { next }
    {
      sign = substr($1, 1, 1)
      path = $0
      sub(/^[ \t]*[-+][ \t]*/, "", path)
      sub(/[ \t]+$/, "", path)
      if (sign == "+")      print "on|"  path
      else if (sign == "-") print "off|" path
      else { printf "ERROR unparseable [modules] line: %s\n", $0 > "/dev/stderr"; exit 2 }
    }
  ' "$1"
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
/Users/slachiewicz/mvn4/sources/switch/test/run-tests.sh
```

Expected: `ok test_mode_modules_ignores_runtime_section`, `ok test_mode_modules_maps_signs_to_states`, `ok test_mode_runtime_reads_value`, then `3 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
cd /Users/slachiewicz/mvn4/sources
git add switch/lib/common.sh switch/test/run-tests.sh
git commit -m "switch: add test harness and mode-file parser"
```

---

### Task 3: The module toggler

The heart of the tool. Flips a `<module>` line between active and commented form without touching anything else.

**Files:**
- Create: `sources/switch/lib/aggregator.sh`
- Create: `sources/switch/test/fixtures/sample-pom.xml`
- Modify: `sources/switch/test/run-tests.sh` (add tests before the final `run_all`)

**Interfaces:**
- Consumes: `log_warn`, `die`, `AGGREGATOR_DIR` from `lib/common.sh`.
- Produces:
  - `agg_module_state POMFILE MODULEPATH` — prints `on` or `off`; exit 3 if the module is not a candidate in that file.
  - `agg_set_module POMFILE MODULEPATH STATE` — rewrites the file in place; exit 3 if not found; no-op write avoided when already in `STATE`.
  - `agg_find_pom ROOT MODULEPATH` — prints the single POM file under `ROOT` declaring that candidate; exit 3 if none, exit 4 if more than one.

- [ ] **Step 1: Write the fixture**

`sources/switch/test/fixtures/sample-pom.xml` — the licence header is deliberately omitted here because this is test data, not a built artifact:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <modules>
    <module>../../../core/build-cache</module>
    <module>../../../core/maven</module>
    <!--module>../../../core/maven-4.0.x</module-->
    <module>../../../core/wrapper</module>
    <!--module>3.x</module-->
    <!-- misc/plugin-testing merged into apache/maven core, see apache/maven#2193 -->
    <!--<module>../../../svn/repository-tools</module>-->
  </modules>
</project>
```

- [ ] **Step 2: Write the failing tests**

Insert into `run-tests.sh` before the final `run_all` line:

```bash
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
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
/Users/slachiewicz/mvn4/sources/switch/test/run-tests.sh
```

Expected: failure sourcing `lib/aggregator.sh` — `No such file or directory`.

- [ ] **Step 4: Write `lib/aggregator.sh`**

Exact string comparison on the trimmed line, so no path ever needs regex escaping.

```bash
#!/usr/bin/env bash
# <ASF licence header — copy verbatim from Task 1>
#
# Reading and flipping <module> entries in aggregator POMs.
# A module is a "candidate" when its line, trimmed, is exactly one of:
#     <module>PATH</module>
#     <!--module>PATH</module-->
# Anything else — prose comments, <!--<module>...</module>--> — is left alone.
# This file is sourced, never executed.

# agg_module_state POMFILE MODULEPATH -> prints "on" | "off"; exit 3 if absent
agg_module_state() {
  local pom="$1" mod="$2" state
  state="$(awk -v mod="$mod" '
    {
      t = $0
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "<module>" mod "</module>")      { print "on";  found = 1; exit }
      if (t == "<!--module>" mod "</module-->") { print "off"; found = 1; exit }
    }
    END { if (!found) exit 3 }
  ' "$pom")" || return 3
  printf '%s\n' "$state"
}

# agg_set_module POMFILE MODULEPATH on|off -> rewrites POMFILE; exit 3 if absent
agg_set_module() {
  local pom="$1" mod="$2" want="$3" tmp current

  case "$want" in
    on|off) ;;
    *) die "agg_set_module: state must be 'on' or 'off', got '$want'" ;;
  esac

  current="$(agg_module_state "$pom" "$mod")" || return 3
  [ "$current" = "$want" ] && return 0

  # Create the temp file NEXT TO the target, not in $TMPDIR: `mv` is only an
  # atomic rename(2) within one filesystem. If $TMPDIR were on another volume,
  # mv would degrade to copy+unlink and a crash mid-copy could leave the real
  # POM partially written.
  # mktemp creates at 0600 and `mv` carries that mode onto the target, so a
  # switch would silently reset every POM it touches from 644 to 600. Git
  # tracks only the exec bit, so this never shows up in `git diff`.
  # `chmod --reference` is GNU-only; capture the mode the BSD way.
  local mode_before; mode_before="$(stat -f %Lp "$pom")"
  tmp="$(mktemp "${pom}.XXXXXX")"
  # awk's exit status MUST be checked before the mv. An awk that dies partway
  # through leaves a truncated $tmp, and an unconditional mv would then destroy
  # the POM's module list.
  if ! awk -v mod="$mod" -v want="$want" '
    {
      t = $0
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "<module>" mod "</module>" || t == "<!--module>" mod "</module-->") {
        match($0, /^[ \t]*/)
        indent = substr($0, 1, RLENGTH)
        if (want == "on") print indent "<module>" mod "</module>"
        else              print indent "<!--module>" mod "</module-->"
        next
      }
      print
    }
  ' "$pom" > "$tmp"; then
    rm -f "$tmp"
    die "agg_set_module: awk failed rewriting $pom (POM left unmodified)"
  fi

  mv "$tmp" "$pom"
  chmod "$mode_before" "$pom"
}

# agg_find_pom ROOT MODULEPATH -> the one POM under ROOT declaring this candidate
# exit 3 if none, exit 4 if ambiguous
agg_find_pom() {
  local root="$1" mod="$2" hits count
  hits="$(
    find "$root" -name pom.xml -not -path '*/target/*' -print0 \
      | xargs -0 awk -v mod="$mod" '
          FNR == 1 { hit = 0 }
          {
            t = $0
            gsub(/^[ \t]+|[ \t]+$/, "", t)
            if (!hit && (t == "<module>" mod "</module>" || t == "<!--module>" mod "</module-->")) {
              print FILENAME
              hit = 1
            }
          }
        '
  )"
  count="$(printf '%s' "$hits" | grep -c . || true)"
  [ "$count" -eq 0 ] && return 3
  [ "$count" -gt 1 ] && { log_error "module '$mod' declared in $count POMs:"; printf '%s\n' "$hits" >&2; return 4; }
  printf '%s\n' "$hits"
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
/Users/slachiewicz/mvn4/sources/switch/test/run-tests.sh
```

Expected: `19 passed, 0 failed` (3 from Task 2, 11 original, 5 new).

- [ ] **Step 6: Commit**

```bash
cd /Users/slachiewicz/mvn4/sources
git add switch/lib/aggregator.sh switch/test/
git commit -m "switch: add aggregator module toggler"
```

---

### Task 4: Maven toolchain management

**Files:**
- Create: `sources/switch/lib/toolchain.sh`
- Modify: `sources/.gitignore` (append three lines)

**Interfaces:**
- Consumes: `log_info`, `die`, `SOURCES_DIR` from `lib/common.sh`.
- Produces:
  - `toolchain_maven_home VERSION` — prints an absolute Maven home. `VERSION=system` resolves the `mvn` on `PATH`; otherwise downloads and verifies `apache-maven-VERSION` into `sources/toolchain/` if not already present.
  - `toolchain_activate MAVENHOME` — re-points `sources/toolchain/current` at `MAVENHOME`.
  - `toolchain_current` — prints the Maven home `current` resolves to, or empty if unset.

- [ ] **Step 1: Append to `sources/.gitignore`**

```
/toolchain/
/switch/cleanup-report.md
/.switch-state
```

- [ ] **Step 2: Write `lib/toolchain.sh`**

```bash
#!/usr/bin/env bash
# <ASF licence header — copy verbatim from Task 1>
#
# Obtaining and selecting a Maven distribution.
# This file is sourced, never executed.

TOOLCHAIN_DIR="$SOURCES_DIR/toolchain"

# Known-good SHA-512 of apache-maven-<version>-bin.tar.gz, one entry per line
# as "<version> <sha512>". Pinning here means a mirror cannot feed us a
# different archive than the one this plan was verified against.
TOOLCHAIN_SHA512='4.0.0-rc-5 942c19fb75ab7a5d2a11001e3d6c8c6214c81d2736ebc613243d22f7b4ab0404092d47511317d767e8f22a1c634a3762cc7e6b4b6693580ac86e73c0bed1bee2'

# toolchain_maven_home VERSION -> absolute Maven home
toolchain_maven_home() {
  local version="$1"

  local home

  if [ "$version" = "system" ]; then
    command -v mvn >/dev/null 2>&1 || die "no 'mvn' on PATH and mode requests the system Maven"
    # Ask Maven itself rather than guessing from the launcher's location.
    # Capture into a variable rather than letting the pipeline print directly:
    # if `mvn -v` ever lacks a "Maven home:" line (wrapper script, changed
    # format, locale), awk prints nothing and the pipeline still exits 0, so the
    # caller would silently receive an empty string instead of a Maven home.
    home="$(mvn -v 2>/dev/null | awk -F': ' '/^Maven home/ { print $2; exit }')"
    [ -n "$home" ] || die "could not parse 'Maven home:' from 'mvn -v' output"
    printf '%s\n' "$home"
    return 0
  fi

  home="$TOOLCHAIN_DIR/apache-maven-$version"
  if [ -x "$home/bin/mvn" ]; then
    printf '%s\n' "$home"
    return 0
  fi

  local expected
  expected="$(printf '%s\n' "$TOOLCHAIN_SHA512" | awk -v v="$version" '$1 == v { print $2; exit }')"
  [ -n "$expected" ] || die "no pinned SHA-512 for Maven $version; add one to TOOLCHAIN_SHA512 in lib/toolchain.sh"

  local file="apache-maven-$version-bin.tar.gz"
  local tmp; tmp="$(mktemp -d)"
  local url
  local ok=""

  mkdir -p "$TOOLCHAIN_DIR"
  for base in "https://dlcdn.apache.org/maven/maven-4" "https://archive.apache.org/dist/maven/maven-4"; do
    url="$base/$version/binaries/$file"
    log_info "downloading $url"
    if curl -fsSL --max-time 600 -o "$tmp/$file" "$url"; then ok=1; break; fi
    log_warn "download failed from $base"
  done
  [ -n "$ok" ] || { rm -rf "$tmp"; die "could not download Maven $version"; }

  local actual
  actual="$(shasum -a 512 "$tmp/$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    rm -rf "$tmp"
    die "SHA-512 mismatch for $file: expected $expected, got $actual"
  fi

  # Extract into a staging directory, then rename into place. Extracting
  # straight into $TOOLCHAIN_DIR is not atomic: a tar interrupted midway (kill,
  # disk full) can leave bin/mvn — an early, small entry in the stream —
  # present while jars are still missing, and the `[ -x "$home/bin/mvn" ]`
  # short-circuit above would then trust that partial install forever, with no
  # further checksum ever run.
  local stage="$TOOLCHAIN_DIR/.staging-$version.$$"
  rm -rf "$stage"
  mkdir -p "$stage"
  if ! tar -xzf "$tmp/$file" -C "$stage"; then
    rm -rf "$tmp" "$stage"
    die "failed to extract $file"
  fi
  rm -rf "$tmp"
  if [ ! -x "$stage/apache-maven-$version/bin/mvn" ]; then
    rm -rf "$stage"
    die "extracted archive did not produce apache-maven-$version/bin/mvn"
  fi
  mv "$stage/apache-maven-$version" "$home"
  rm -rf "$stage"
  printf '%s\n' "$home"
}

# toolchain_activate MAVENHOME
toolchain_activate() {
  local home="$1"
  [ -x "$home/bin/mvn" ] || die "not a Maven home: $home"
  mkdir -p "$TOOLCHAIN_DIR"
  ln -sfn "$home" "$TOOLCHAIN_DIR/current"
}

# toolchain_current -> resolved Maven home, or empty
toolchain_current() {
  [ -L "$TOOLCHAIN_DIR/current" ] || return 0
  # The subshell is load-bearing. This file is sourced, so a bare `cd` in a
  # function body changes the CALLER's working directory. `mvn-switch` calls
  # this from cmd_status and then does further relative work; a leaked cd would
  # corrupt it in a way that is painful to debug. Safe for every call style,
  # not only command substitution.
  # `|| return 0` is load-bearing: a DANGLING `current` symlink passes the
  # -L test but fails the cd, and this function's contract is "home, or
  # empty". Returning non-zero here kills `mvn-switch status` outright under
  # the caller's set -e, before it ever reaches the drift check.
  ( cd -P "$TOOLCHAIN_DIR/current" 2>/dev/null && pwd ) || return 0
}
```

- [ ] **Step 3: Verify the system path resolves**

```bash
cd /Users/slachiewicz/mvn4/sources/switch/lib && \
bash -c '. ./common.sh; . ./toolchain.sh; toolchain_maven_home system'
```

Expected: `/opt/homebrew/Cellar/maven/3.9.16/libexec`

- [ ] **Step 4: Verify the download path, checksum and activation**

```bash
cd /Users/slachiewicz/mvn4/sources/switch/lib && \
bash -c '. ./common.sh; . ./toolchain.sh; h=$(toolchain_maven_home 4.0.0-rc-5); toolchain_activate "$h"; "$SOURCES_DIR/toolchain/current/bin/mvn" -v | head -1'
```

Expected: the download runs once, then `Apache Maven 4.0.0-rc-5 (...)`. Re-running must not download again.

- [ ] **Step 5: Verify a corrupted archive is rejected**

Proves the checksum gate actually fires rather than being decorative.

```bash
cd /Users/slachiewicz/mvn4/sources/switch/lib && \
bash -c '. ./common.sh; . ./toolchain.sh
TOOLCHAIN_SHA512="4.0.0-rc-5 0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
rm -rf "$TOOLCHAIN_DIR/apache-maven-4.0.0-rc-5"
toolchain_maven_home 4.0.0-rc-5' ; echo "exit=$?"
```

Expected: `ERROR SHA-512 mismatch for apache-maven-4.0.0-rc-5-bin.tar.gz: ...` and `exit=1`. Then re-run Step 4 to restore the real distribution.

- [ ] **Step 6: Commit**

```bash
cd /Users/slachiewicz/mvn4/sources
git add switch/lib/toolchain.sh .gitignore
git commit -m "switch: add Maven toolchain download and selection"
```

---

### Task 5: The `mvn-switch` entry point

Wires the three libraries together. Written before the migration so it can be exercised against today's aggregator; the mode files it consumes arrive in Task 8.

**Files:**
- Create: `sources/mvn-switch`

**Interfaces:**
- Consumes: everything produced by Tasks 2–4.
- Produces: the CLI contract —
  - `./mvn-switch <mode> [--dry-run]` — apply a mode.
  - `./mvn-switch status` — print active mode, resolved `mvn -v`, and any module whose state disagrees with the active mode.
  - `./mvn-switch list` — list available modes.
  - `./mvn-switch cleanup [--apply]` — dispatches to Task 9; until then it exits 1 with "not implemented".
  - `sources/.switch-state` — two lines, `mode=<name>` and `maven=<version>`.

- [ ] **Step 1: Write the entry point**

```bash
#!/usr/bin/env bash
# <ASF licence header — copy verbatim from Task 1>
#
# Select the build configuration of this checkout.
#
#   ./mvn-switch mvn3 | mvn4 | mvn4-3xplugins [--dry-run]
#   ./mvn-switch status
#   ./mvn-switch list
#   ./mvn-switch cleanup [--apply]

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/switch/lib/common.sh"
. "$SELF_DIR/switch/lib/aggregator.sh"
. "$SELF_DIR/switch/lib/toolchain.sh"

STATE_FILE="$SOURCES_DIR/.switch-state"

# Temp files are script-global and cleaned by a trap, so a `die` from inside a
# loop body cannot leak them. `rm -f ""` is a harmless no-op when unset.
TMP_PLAN=""
TMP_MODLIST=""
trap 'rm -f "$TMP_PLAN" "$TMP_MODLIST"' EXIT

# read_modules MODEFILE -> populates TMP_MODLIST, dies if the mode file is
# malformed. Do NOT feed a loop with `< <(mode_modules …)`: process
# substitution is not covered by `pipefail` and its exit status is invisible,
# so `mode_modules`' exit 2 on a malformed [modules] line would be swallowed
# and the loop would silently process a TRUNCATED module list as if complete —
# the exact partial-application failure the two-pass design exists to prevent.
read_modules() {
  local modefile="$1"
  TMP_MODLIST="$(mktemp)"
  if ! mode_modules "$modefile" > "$TMP_MODLIST"; then
    die "mode file '$modefile' has a malformed [modules] section; nothing was changed"
  fi
}

usage() {
  cat >&2 <<EOF
usage: mvn-switch <mode> [--dry-run]
       mvn-switch status
       mvn-switch list
       mvn-switch cleanup [--apply]

modes: $(ls "$MODES_DIR" 2>/dev/null | sed 's/\.mode$//' | tr '\n' ' ')
EOF
  exit 1
}

cmd_list() {
  local m
  for m in "$MODES_DIR"/*.mode; do
    [ -f "$m" ] || continue
    printf '%-16s runtime %s\n' "$(basename "$m" .mode)" "$(mode_runtime "$m")"
  done
}

cmd_apply() {
  local mode="$1" dry="$2"
  local modefile; modefile="$(mode_path "$mode")"
  local runtime;  runtime="$(mode_runtime "$modefile")"
  [ -n "$runtime" ] || die "mode '$mode' has no [runtime] maven value"

  local changed=0 already=0 want path pom state rc

  # Resolve every module to its POM first, so a bad module aborts before any
  # file is written.
  read_modules "$modefile"
  # A mode that resolves to zero modules is never legitimate — every mode is a
  # complete description of the toggleable set. Refusing it turns any future
  # parser gap into a loud failure instead of a silent no-op switch.
  [ -s "$TMP_MODLIST" ] || die "mode '$mode' resolved to no modules at all; refusing to switch (check its [modules] section)"
  TMP_PLAN="$(mktemp)"
  while IFS='|' read -r want path; do
    [ -n "$path" ] || continue
    pom="$(agg_find_pom "$AGGREGATOR_DIR" "$path")" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
      # Distinguish the two failures: agg_find_pom already logged the competing
      # paths for the ambiguous case, so claiming "not a candidate" there would
      # contradict it.
      case "$rc" in
        4) die "module '$path' (mode $mode) is declared in more than one aggregator POM (listed above); nothing was changed" ;;
        *) die "module '$path' (mode $mode) is not a candidate in any aggregator POM; nothing was changed" ;;
      esac
    fi
    printf '%s|%s|%s\n' "$want" "$path" "$pom" >> "$TMP_PLAN"
  done < "$TMP_MODLIST"

  while IFS='|' read -r want path pom; do
    state="$(agg_module_state "$pom" "$path")"
    if [ "$state" = "$want" ]; then
      already=$((already + 1))
      continue
    fi
    changed=$((changed + 1))
    if [ "$dry" = "1" ]; then
      printf 'would set %-3s %s  (%s)\n' "$want" "$path" "${pom#"$SOURCES_DIR"/}"
    else
      agg_set_module "$pom" "$path" "$want"
      printf 'set %-3s %s\n' "$want" "$path"
    fi
  done < "$TMP_PLAN"

  local home
  if [ "$dry" = "1" ]; then
    # A dry run must write NOTHING. toolchain_maven_home downloads and extracts
    # a distribution when the version is absent, so it must not be called here
    # for an uncached version — report the intent instead.
    if [ "$runtime" = "system" ]; then
      home="$(toolchain_maven_home system)"
    elif [ -x "$TOOLCHAIN_DIR/apache-maven-$runtime/bin/mvn" ]; then
      home="$TOOLCHAIN_DIR/apache-maven-$runtime"
    else
      home="(not yet downloaded; would fetch Maven $runtime into $TOOLCHAIN_DIR)"
    fi
    printf 'would activate Maven home %s\n' "$home"
    printf '\ndry run: %d modules would change, %d already correct\n' "$changed" "$already"
    return 0
  fi

  home="$(toolchain_maven_home "$runtime")"
  toolchain_activate "$home"
  printf 'mode=%s\nmaven=%s\n' "$mode" "$runtime" > "$STATE_FILE"

  printf '\nmode %s active: %d modules changed, %d already correct\n' "$mode" "$changed" "$already"
  printf 'Maven home: %s\n' "$home"
  cat <<EOF

Add this to your shell profile once, if you have not already:
  export PATH="$SOURCES_DIR/toolchain/current/bin:\$PATH"

Then:
  cd $AGGREGATOR_DIR && mvn install -DskipTests
EOF
}

cmd_status() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "no mode active (run: mvn-switch <mode>)"
    return 0
  fi
  local mode; mode="$(awk -F= '$1 == "mode" { print $2 }' "$STATE_FILE")"
  printf 'active mode: %s\n' "$mode"

  local home; home="$(toolchain_current)"
  if [ -n "$home" ]; then
    printf 'Maven home:  %s\n' "$home"
    # Both halves can fail under `set -o pipefail`: mvn exits non-zero on a
    # broken JAVA_HOME, and head exiting first can SIGPIPE mvn. Either would
    # abort cmd_status before the drift report, which is the point of status.
    "$home/bin/mvn" -v 2>/dev/null | head -1 || true
  else
    log_warn "toolchain/current is not set"
  fi

  local modefile drift=0 want path pom state rc
  modefile="$(mode_path "$mode")"
  read_modules "$modefile"
  while IFS='|' read -r want path; do
    [ -n "$path" ] || continue
    # A module that has vanished from the aggregator entirely is the most
    # severe drift there is; report it rather than skipping it silently.
    pom="$(agg_find_pom "$AGGREGATOR_DIR" "$path")" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
      [ "$drift" -eq 0 ] && printf '\ndrift from mode %s:\n' "$mode"
      # Must distinguish 4 from 3: agg_find_pom has already written "declared
      # in N POMs" plus the competing paths to stderr, so printing NOT FOUND
      # here would contradict it in the same terminal.
      if [ "$rc" -eq 4 ]; then
        printf '  %-46s AMBIGUOUS - declared in more than one POM\n' "$path"
      else
        printf '  %-46s NOT FOUND in any aggregator POM\n' "$path"
      fi
      drift=$((drift + 1))
      continue
    fi
    state="$(agg_module_state "$pom" "$path")"
    if [ "$state" != "$want" ]; then
      [ "$drift" -eq 0 ] && printf '\ndrift from mode %s:\n' "$mode"
      printf '  %-46s is %-3s expected %s\n' "$path" "$state" "$want"
      drift=$((drift + 1))
    fi
  done < "$TMP_MODLIST"
  [ "$drift" -eq 0 ] && printf '\naggregator matches mode %s\n' "$mode"
  return 0
}

[ $# -ge 1 ] || usage

case "$1" in
  status)  cmd_status ;;
  list)    cmd_list ;;
  cleanup)
    if [ -f "$SELF_DIR/switch/lib/cleanup.sh" ]; then
      . "$SELF_DIR/switch/lib/cleanup.sh"
      shift
      cleanup_main "$@"
    else
      die "cleanup is not implemented yet"
    fi
    ;;
  -h|--help) usage ;;
  *)
    mode="$1"; shift
    dry=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) dry=1 ;;
        *) usage ;;
      esac
      shift
    done
    cmd_apply "$mode" "$dry"
    ;;
esac
```

- [ ] **Step 2: Verify argument handling before any mode files exist**

```bash
chmod +x /Users/slachiewicz/mvn4/sources/mvn-switch
cd /Users/slachiewicz/mvn4/sources
./mvn-switch list; echo "exit=$?"
./mvn-switch nosuchmode 2>&1 | head -2; ./mvn-switch status
```

Expected: `list` prints nothing and exits 0 (no modes yet); `nosuchmode` prints `ERROR unknown mode 'nosuchmode'; available: `; `status` prints `no mode active (run: mvn-switch <mode>)`.

- [ ] **Step 3: Verify the dry run against a throwaway mode**

```bash
cd /Users/slachiewicz/mvn4/sources
cat > switch/modes/scratch.mode <<'EOF'
[runtime]
maven = system

[modules]
+ ../../../core/maven-4.0.x
- ../../../core/maven
EOF
./mvn-switch scratch --dry-run
git diff --stat aggregator/
```

Expected: two `would set` lines naming `aggregator/core/pom.xml`, a `would activate Maven home /opt/homebrew/...` line, `dry run: 2 modules would change, 0 already correct`, and **an empty `git diff`** — a dry run must write nothing.

- [ ] **Step 4: Verify the unknown-module abort writes nothing**

```bash
cd /Users/slachiewicz/mvn4/sources
cat > switch/modes/scratch.mode <<'EOF'
[runtime]
maven = system

[modules]
- ../../../core/maven
+ this-module-does-not-exist
EOF
./mvn-switch scratch; echo "exit=$?"
git diff --stat aggregator/
```

Expected: `ERROR module 'this-module-does-not-exist' (mode scratch) is not a candidate in any aggregator POM`, `exit=1`, and an empty `git diff` — the resolve-everything-first pass must prevent a partial application.

- [ ] **Step 5: Remove the scratch mode and commit**

```bash
cd /Users/slachiewicz/mvn4/sources
rm switch/modes/scratch.mode
git add mvn-switch
git commit -m "switch: add mvn-switch entry point"
```

---

### Task 6: Migrate `.repo` to the master manifest

Irreversible. Task 1 must be complete and its Step 3 restore check must have passed.

**Files:**
- Create: `sources/switch/migrate/verify-migration.sh`
- Modifies: `.repo/` (not under version control)

**Interfaces:**
- Consumes: `~/mvn4-archive/MANIFEST.txt` from Task 1.
- Produces: a checkout matching `sources/default.xml` on `master`, with the 15 new project paths present on disk.

- [ ] **Step 1: Record the pre-migration baseline**

```bash
cd /Users/slachiewicz/mvn4
repo forall -c 'printf "%s|%s\n" "$REPO_PATH" "$(git rev-parse HEAD)"' 2>/dev/null \
  | sort > ~/mvn4-archive/pre-migration-heads.txt
wc -l < ~/mvn4-archive/pre-migration-heads.txt
```

Expected: 134 (the checkout has more projects than the 128 measured during design; the count is informational, not a gate).

- [ ] **Step 2: Preserve the local `sources` commit**

`sources` is one commit ahead of `origin/master` (`e93a253`, removing the `misc/plugin-testing` module) and now also carries Tasks 1–5. `repo init` does not touch a project's worktree, but capture the SHA so any loss is detectable.

```bash
cd /Users/slachiewicz/mvn4/sources
git log --oneline origin/master..HEAD > ~/mvn4-archive/sources-unpushed.txt
cat ~/mvn4-archive/sources-unpushed.txt
```

Expected: a list including `e93a253 Remove stale misc/plugin-testing module` and the Task 1–5 commits.

- [ ] **Step 3: Re-initialise onto the master manifest**

```bash
cd /Users/slachiewicz/mvn4
repo init -u https://gitbox.apache.org/repos/asf/maven-sources.git -b master
git -C .repo/manifests rev-parse --abbrev-ref HEAD
grep -c "core/maven-4.0.x" .repo/manifests/default.xml
```

Expected: `master`, and `1`.

- [ ] **Step 3a: Repair `.repo/manifests` if `repo init` fails**

`repo init -b master` deletes the old local branch in `.repo/manifests` before creating the new
one, and can abort in between — leaving `HEAD` pointing at a `refs/heads/<old>` that no longer
exists, with `rev-parse HEAD` failing. Project worktrees are untouched by `repo init`, so this is
repairable forward:

```bash
cd /Users/slachiewicz/mvn4/.repo/manifests
git update-ref refs/heads/master refs/remotes/origin/master
git symbolic-ref HEAD refs/heads/master
git reset --hard master
```

Then re-run Step 3. Note `repo` may keep the local branch *named* `default` while setting
`merge = refs/heads/master`; that is normal. Verify by content, not by branch name:
`grep -c "core/maven-4.0.x" .repo/manifests/default.xml` must be 1.

- [ ] **Step 3b: Displace `misc/gh-actions-shared` before syncing**

The master manifest replaces the project at `misc/gh-actions-shared` with two projects *nested
inside that same path*, `misc/gh-actions-shared/{main,v4}`. `repo` creates the children, which
makes the parent look dirty, and then refuses to remove it:
`error: misc/gh-actions-shared: Cannot remove project: uncommitted changes are present.`
This blocks the whole sync. Move the old project aside first — its `include-option` branch
carries local-only work, so confirm the bundle restores before moving:

```bash
cd /tmp && rm -rf ghas-check
git clone --mirror ~/mvn4-archive/misc_gh-actions-shared.bundle ghas-check
git -C ghas-check rev-parse include-option
git -C /Users/slachiewicz/mvn4/misc/gh-actions-shared rev-parse include-option   # must match
mkdir -p ~/mvn4-archive/displaced
mv /Users/slachiewicz/mvn4/misc/gh-actions-shared ~/mvn4-archive/displaced/gh-actions-shared
```

- [ ] **Step 4: Sync — `--detach` is mandatory**

```bash
cd /Users/slachiewicz/mvn4
repo sync --detach -j8 2>&1 | tail -20
```

**Do not run a plain `repo sync`.** Nine projects change manifest revision from `master` to their
`-3.x` line (the five `plugins/core/*`, two `plugins/packaging/*`, two `shared/*`). A plain sync
tries to *rebase the checked-out branch onto the new revision* — rebasing the Maven 4 line onto
the 3.x line — which conflicts in `pom.xml` for every one of them and leaves each repository
mid-rebase. Recovery is `git rebase --abort` per repository, but `--detach` avoids it entirely.

If a plain sync was already run, clear the wreckage before retrying:

```bash
cd /Users/slachiewicz/mvn4
for d in plugins/core/maven-clean-plugin plugins/core/maven-compiler-plugin \
         plugins/core/maven-deploy-plugin plugins/core/maven-install-plugin \
         plugins/core/maven-resources-plugin plugins/packaging/maven-jar-plugin \
         plugins/packaging/maven-source-plugin shared/archiver shared/filtering; do
  gd="$(git -C "$d" rev-parse --absolute-git-dir)"
  if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
    git -C "$d" rebase --abort
  fi
done
```

`--absolute-git-dir` matters: `--git-dir` returns a path relative to the repository, so testing
`[ -d "$(git -C "$d" rev-parse --git-dir)/rebase-merge" ]` from the checkout root silently
reports every repository as clean when they are not.

- [ ] **Step 4a: Restore the tooling branch**

`repo sync --detach` detaches every project, including `sources`. The commits are safe on the
branch; the working tree simply is not showing them. Restore it:

```bash
git -C /Users/slachiewicz/mvn4/sources switch mvn-switch-tooling
```

- [ ] **Step 5: Write the verification script**

```bash
#!/usr/bin/env bash
# <ASF licence header — copy verbatim from Task 1>
#
# Assert that the checkout matches the master manifest and that nothing that
# carried local-only work vanished without an archive.

set -euo pipefail

CHECKOUT_ROOT="${CHECKOUT_ROOT:-$HOME/mvn4}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$HOME/mvn4-archive}"
rc=0

cd "$CHECKOUT_ROOT"

echo "== new project paths required by the master manifest =="
for p in \
  core/maven-4.0.x core/3.x/maven-3 core/3.x/mvnd-1 core/3.x/its-3 \
  plugins/core-4/maven-clean-plugin plugins/core-4/maven-compiler-plugin \
  plugins/core-4/maven-deploy-plugin plugins/core-4/maven-install-plugin \
  plugins/core-4/maven-resources-plugin \
  plugins/packaging-4/maven-jar-plugin plugins/packaging-4/maven-source-plugin \
  shared-4/archiver shared-4/filtering \
  misc/gh-actions-shared/main misc/gh-actions-shared/v4
do
  if [ -e "$p/pom.xml" ] || [ -d "$p/.git" ]; then
    printf '  ok      %s\n' "$p"
  else
    printf '  MISSING %s\n' "$p"; rc=1
  fi
done

echo
echo "== the 3.x line must really be 3.x, the 4 line really 4 =="
check_version() {
  local path="$1" want="$2" got
  got=$(awk '/<\/parent>/ { p = 1 } p && /<version>/ { gsub(/.*<version>|<\/version>.*/, ""); print; exit }' "$path/pom.xml")
  if [ "$got" = "$want" ]; then printf '  ok      %-24s %s\n' "$path" "$got"
  else printf '  WRONG   %-24s got %s want %s\n' "$path" "$got" "$want"; rc=1; fi
}
check_version core/maven-4.0.x 4.0.0-SNAPSHOT
check_version core/3.x/maven-3 3.10.0-SNAPSHOT

echo
echo "== every repository that held local-only commits is still restorable =="
awk -F'|' '$4 > 0 { print $1 }' "$ARCHIVE_DIR/MANIFEST.txt" | while read -r p; do
  safe=$(printf '%s' "$p" | tr '/' '_')
  if [ -f "$ARCHIVE_DIR/$safe.bundle" ]; then printf '  ok      %s\n' "$p"
  else printf '  NO BUNDLE %s\n' "$p"; fi
done

exit $rc
```

- [ ] **Step 6: Run the verification**

```bash
chmod +x /Users/slachiewicz/mvn4/sources/switch/migrate/verify-migration.sh
/Users/slachiewicz/mvn4/sources/switch/migrate/verify-migration.sh; echo "exit=$?"
```

Expected: `exit=0` with every line `ok`. If `core/3.x/maven-3` reports a version other than `3.10.0-SNAPSHOT`, update the expected value in the script to whatever `maven-3.10.x` actually carries and note it — the manifest is the authority, not this plan.

- [ ] **Step 7: Commit**

```bash
cd /Users/slachiewicz/mvn4/sources
git add switch/migrate/verify-migration.sh
git commit -m "switch: add post-migration verification"
```

---

### Task 7: The four missing aggregator POM trees

**Files:**
- Create: `sources/aggregator/core/3.x/pom.xml`
- Create: `sources/aggregator/plugins/core-4/pom.xml`
- Create: `sources/aggregator/plugins/packaging-4/pom.xml`
- Create: `sources/aggregator/shared-4/pom.xml`
- Modify: `sources/aggregator/shared/pom.xml` (no content change; confirm `archiver` and `filtering` lines are candidates)

**Interfaces:**
- Consumes: the directories created by Task 6.
- Produces: module candidates named by the mode files in Task 8 — `3.x`, `core-4`, `packaging-4`, `shared-4` and the per-module paths beneath them.

- [ ] **Step 1: Create `aggregator/core/3.x/pom.xml`**

Parent is `core`, whose `artifactId` is `core` — confirm with `grep artifactId sources/aggregator/core/pom.xml` before writing.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!-- ASF licence header — copy verbatim from sources/aggregator/pom.xml -->
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.apache.maven.aggregator</groupId>
    <artifactId>core</artifactId>
    <version>1.0-SNAPSHOT</version>
  </parent>
  <artifactId>core-3x</artifactId>
  <packaging>pom</packaging>

  <name>Aggregator POM for the Maven 3.x core line</name>
  <modules>
    <module>../../../../core/3.x/maven-3</module>
    <module>../../../../core/3.x/mvnd-1</module>
    <!--module>../../../../core/3.x/its-3</module-->
  </modules>
</project>
```

`its-3` starts commented: integration tests are not part of `install -DskipTests` and pull in a full Maven distribution.

- [ ] **Step 2: Create `aggregator/plugins/core-4/pom.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!-- ASF licence header — copy verbatim from sources/aggregator/pom.xml -->
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.apache.maven.aggregator</groupId>
    <artifactId>plugins</artifactId>
    <version>1.0-SNAPSHOT</version>
  </parent>
  <artifactId>plugins-core-4</artifactId>
  <packaging>pom</packaging>

  <name>Aggregator POM for Maven 4 native core plugins</name>
  <modules>
    <module>../../../../plugins/core-4/maven-clean-plugin</module>
    <module>../../../../plugins/core-4/maven-compiler-plugin</module>
    <module>../../../../plugins/core-4/maven-deploy-plugin</module>
    <module>../../../../plugins/core-4/maven-install-plugin</module>
    <module>../../../../plugins/core-4/maven-resources-plugin</module>
  </modules>
</project>
```

- [ ] **Step 3: Create `aggregator/plugins/packaging-4/pom.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!-- ASF licence header — copy verbatim from sources/aggregator/pom.xml -->
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.apache.maven.aggregator</groupId>
    <artifactId>plugins</artifactId>
    <version>1.0-SNAPSHOT</version>
  </parent>
  <artifactId>plugins-packaging-4</artifactId>
  <packaging>pom</packaging>

  <name>Aggregator POM for Maven 4 native packaging plugins</name>
  <modules>
    <module>../../../../plugins/packaging-4/maven-jar-plugin</module>
    <module>../../../../plugins/packaging-4/maven-source-plugin</module>
  </modules>
</project>
```

- [ ] **Step 4: Create `aggregator/shared-4/pom.xml`**

Parent is the top-level `maven-aggregator`, so the relative depth is one level shallower than the plugins trees.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!-- ASF licence header — copy verbatim from sources/aggregator/pom.xml -->
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.apache.maven.aggregator</groupId>
    <artifactId>maven-aggregator</artifactId>
    <version>1.0-SNAPSHOT</version>
  </parent>
  <artifactId>shared-4</artifactId>
  <packaging>pom</packaging>

  <name>Aggregator POM for Maven 4 native shared components</name>
  <modules>
    <module>../../../shared-4/archiver</module>
    <module>../../../shared-4/filtering</module>
  </modules>
</project>
```

- [ ] **Step 5: Verify every relative module path resolves**

A wrong `../` depth is the most likely error in this task and Maven's message for it is unhelpful.

```bash
cd /Users/slachiewicz/mvn4/sources/aggregator
for f in core/3.x/pom.xml plugins/core-4/pom.xml plugins/packaging-4/pom.xml shared-4/pom.xml; do
  d=$(dirname "$f")
  grep -oE '<module>[^<]+' "$f" | sed 's/<module>//' | while read -r m; do
    if [ -f "$d/$m/pom.xml" ]; then printf 'ok      %s -> %s\n' "$f" "$m"
    else printf 'BROKEN  %s -> %s\n' "$f" "$m"; fi
  done
done
```

Expected: every line `ok`. Any `BROKEN` line means the `../` depth is wrong — fix it before continuing.

- [ ] **Step 6: Confirm the new trees are reachable as candidates**

```bash
cd /Users/slachiewicz/mvn4/sources
for m in 3.x core-4 packaging-4 shared-4 ../../../core/maven-4.0.x; do
  printf '%-32s ' "$m"
  bash -c ". switch/lib/common.sh; . switch/lib/aggregator.sh; agg_find_pom \"\$AGGREGATOR_DIR\" '$m'" \
    || echo "NOT A CANDIDATE"
done
```

Expected: `3.x` → `aggregator/core/pom.xml`; `core-4` and `packaging-4` → `aggregator/plugins/pom.xml`; `shared-4` and `../../../core/maven-4.0.x` → `aggregator/pom.xml` and `aggregator/core/pom.xml` respectively. All five already exist as commented candidates, so none should report `NOT A CANDIDATE`.

- [ ] **Step 7: Commit**

```bash
cd /Users/slachiewicz/mvn4/sources
git add aggregator/core/3.x/pom.xml aggregator/plugins/core-4/pom.xml \
        aggregator/plugins/packaging-4/pom.xml aggregator/shared-4/pom.xml
git commit -m "aggregator: add POM trees for the 3.x and Maven 4 native lines"
```

---

### Task 8: The three mode files

Each mode names **every** toggleable module, so modes are complete states rather than deltas and switching is order-independent.

**Files:**
- Create: `sources/switch/modes/mvn3.mode`
- Create: `sources/switch/modes/mvn4.mode`
- Create: `sources/switch/modes/mvn4-3xplugins.mode`

**Interfaces:**
- Consumes: candidates from Task 7, and the existing candidates `../../../core/maven`, `../../../core/maven-4.0.x`, `3.x`, `core-4`, `packaging-4`, `shared-4`.
- Produces: the toggleable-module set. Every path here must satisfy `agg_find_pom`.

- [ ] **Step 1: Make the five `plugins/core` and two `plugins/packaging` and two `shared` entries toggleable**

They are currently plain `<module>` lines, which is the "on" form — already valid candidates, so no edit is needed. Confirm:

```bash
cd /Users/slachiewicz/mvn4/sources
for m in ../../../../plugins/core/maven-clean-plugin \
         ../../../../plugins/packaging/maven-jar-plugin \
         ../../../shared/archiver ; do
  printf '%-52s ' "$m"
  bash -c ". switch/lib/common.sh; . switch/lib/aggregator.sh; agg_find_pom \"\$AGGREGATOR_DIR\" '$m'"
done
```

Expected: `aggregator/plugins/core/pom.xml`, `aggregator/plugins/packaging/pom.xml`, `aggregator/shared/pom.xml`.

- [ ] **Step 2: Write `modes/mvn3.mode`**

```ini
# Maven 3 line: 3.10.x core, all plugins and shared components on their 3.x branches.
[runtime]
maven = system

[modules]
# core
- ../../../core/maven
- ../../../core/maven-4.0.x
+ 3.x
# core plugins: 3.x line on, 4-native line off
+ ../../../../plugins/core/maven-clean-plugin
+ ../../../../plugins/core/maven-compiler-plugin
+ ../../../../plugins/core/maven-deploy-plugin
+ ../../../../plugins/core/maven-install-plugin
+ ../../../../plugins/core/maven-resources-plugin
- core-4
# packaging plugins
+ ../../../../plugins/packaging/maven-jar-plugin
+ ../../../../plugins/packaging/maven-source-plugin
- packaging-4
# shared components
+ ../../../shared/archiver
+ ../../../shared/filtering
- shared-4
```

- [ ] **Step 3: Write `modes/mvn4.mode`**

```ini
# Maven 4 line: 4.0.x core, 4-native plugins and shared components where they exist.
[runtime]
maven = 4.0.0-rc-5

[modules]
# core
- ../../../core/maven
+ ../../../core/maven-4.0.x
- 3.x
# core plugins: 4-native line on, 3.x line off
- ../../../../plugins/core/maven-clean-plugin
- ../../../../plugins/core/maven-compiler-plugin
- ../../../../plugins/core/maven-deploy-plugin
- ../../../../plugins/core/maven-install-plugin
- ../../../../plugins/core/maven-resources-plugin
+ core-4
# packaging plugins
- ../../../../plugins/packaging/maven-jar-plugin
- ../../../../plugins/packaging/maven-source-plugin
+ packaging-4
# shared components
- ../../../shared/archiver
- ../../../shared/filtering
+ shared-4
```

- [ ] **Step 4: Write `modes/mvn4-3xplugins.mode`**

```ini
# Maven 4.0.x core running an all-3.x plugin and shared-component set.
[runtime]
maven = 4.0.0-rc-5

[modules]
# core
- ../../../core/maven
+ ../../../core/maven-4.0.x
- 3.x
# core plugins: 3.x line on, 4-native line off
+ ../../../../plugins/core/maven-clean-plugin
+ ../../../../plugins/core/maven-compiler-plugin
+ ../../../../plugins/core/maven-deploy-plugin
+ ../../../../plugins/core/maven-install-plugin
+ ../../../../plugins/core/maven-resources-plugin
- core-4
# packaging plugins
+ ../../../../plugins/packaging/maven-jar-plugin
+ ../../../../plugins/packaging/maven-source-plugin
- packaging-4
# shared components
+ ../../../shared/archiver
+ ../../../shared/filtering
- shared-4
```

- [ ] **Step 5: Dry-run all three**

```bash
cd /Users/slachiewicz/mvn4/sources
for m in mvn3 mvn4 mvn4-3xplugins; do echo "=== $m ==="; ./mvn-switch "$m" --dry-run; done
git diff --stat aggregator/
```

Expected: each mode reports its changes with no error, and `git diff` is empty.

- [ ] **Step 6: Prove idempotence and order-independence**

```bash
cd /Users/slachiewicz/mvn4/sources
./mvn-switch mvn3 >/dev/null && git status --porcelain aggregator/ > /tmp/a.txt && find aggregator -name pom.xml -not -path '*/target/*' | sort | xargs shasum | shasum > /tmp/h1.txt
./mvn-switch mvn4 >/dev/null
./mvn-switch mvn3 >/dev/null && find aggregator -name pom.xml -not -path '*/target/*' | sort | xargs shasum | shasum > /tmp/h2.txt
diff /tmp/h1.txt /tmp/h2.txt && echo "ROUND TRIP CLEAN"
./mvn-switch mvn3 >/dev/null && ./mvn-switch status | tail -1
```

Expected: `ROUND TRIP CLEAN`, then `aggregator matches mode mvn3`.

- [ ] **Step 7: Commit**

```bash
cd /Users/slachiewicz/mvn4/sources
git add switch/modes/
git commit -m "switch: add mvn3, mvn4 and mvn4-3xplugins mode definitions"
```

---

### Task 9: Branch cleanup

Independent of the switcher; safe to run at any point after Task 6.

**Files:**
- Create: `sources/switch/lib/cleanup.sh`
- Modify: `sources/switch/test/run-tests.sh` (add tests before the final `run_all`)

**Interfaces:**
- Consumes: `log_info`, `log_warn`, `die` from `lib/common.sh`.
- Produces:
  - `cleanup_classify REPODIR` — prints `BRANCH|CLASS|SHA|LOCALONLY|DATE|SUBJECT`, one per local branch. `CLASS` is one of `current`, `redundant`, `stale-dependabot`, `local-only`.
  - `cleanup_main [--apply]` — the subcommand `mvn-switch cleanup` dispatches to.
  - `sources/switch/cleanup-report.md`.

- [ ] **Step 1: Write the failing tests**

Insert into `run-tests.sh` before the final `run_all` line:

```bash
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

  # stale dependabot: local commits, and no origin/<same name>
  git -C "$d" checkout -q -b dependabot/maven/foo-1.0 master
  git -C "$d" commit -q --allow-empty -m "bump foo"

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
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
/Users/slachiewicz/mvn4/sources/switch/test/run-tests.sh
```

Expected: failure sourcing `lib/cleanup.sh` — `No such file or directory`.

- [ ] **Step 3: Write `lib/cleanup.sh`**

```bash
#!/usr/bin/env bash
# <ASF licence header — copy verbatim from Task 1>
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
      # `rev-parse --abbrev-ref HEAD` reads back the literal string "HEAD" in
      # a detached repo — the normal state after `repo sync --detach`, true
      # for 131 of 132 repos here. No branch name matches that, so without
      # the SHA fallback the current-branch guard is silently a no-op almost
      # everywhere.
      class=current
    elif [ "$localonly" -eq 0 ]; then
      class=redundant
    elif case "$branch" in dependabot/*) true ;; *) false ;; esac \
         && ! git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$branch" \
         && [ "$(git -C "$d" log --format=%ae "$branch" --not --remotes | grep -vc dependabot)" -eq 0 ]; then
      # The author check is NOT optional. A dependabot branch whose PR was
      # closed is disposable ONLY if every unpushed commit on it is the bot's.
      # People routinely commit fixes on top of a bump branch and never push
      # them; without this guard those commits are classified stale and
      # deleted. Measured on the real checkout: 18 of 40 orphaned dependabot
      # branches carried human commits, two of them four commits deep.
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
          printf '| `%s` | `%s` | redundant |\n' "$path" "$branch" >> "$deleted_list"
          ;;
        stale-dependabot)
          stale=$((stale + 1))
          printf '| `%s` | `%s` | stale-dependabot |\n' "$path" "$branch" >> "$deleted_list"
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
    printf '\n## Summary\n\n'
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
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
/Users/slachiewicz/mvn4/sources/switch/test/run-tests.sh
```

Expected: `19 passed, 0 failed`.

- [ ] **Step 5: Dry-run against the real checkout**

```bash
cd /Users/slachiewicz/mvn4/sources
./mvn-switch cleanup
head -20 switch/cleanup-report.md
```

Expected: a summary in the shape `total ~354  redundant ~218  stale-dependabot ~40  kept ~96`. Exact counts will differ after the Task 6 migration changed which projects exist — the report is the authority, not these figures. **Read the kept list before proceeding.**

- [ ] **Step 6: Apply, then prove recovery works**

```bash
cd /Users/slachiewicz/mvn4/sources
./mvn-switch cleanup --apply
git -C /Users/slachiewicz/mvn4/core/maven tag -l 'archive/*' | head -5
git -C /Users/slachiewicz/mvn4/core/maven log --oneline -1 archive/MNG-7531
```

Expected: archive tags exist and resolve to commits. If `archive/MNG-7531` is absent because that branch no longer exists post-migration, use any tag from the listing instead.

- [ ] **Step 7: Commit**

```bash
cd /Users/slachiewicz/mvn4/sources
git add switch/lib/cleanup.sh switch/test/run-tests.sh
git commit -m "switch: add local branch cleanup with archive tags"
```

---

### Task 10: Build each mode and record what fails

The empirical task. Its deliverable is an accurate failure inventory, **not** a green build — do not disable modules to manufacture a pass without recording why.

**Files:**
- Create: `sources/switch/BUILD-STATUS.md`
- Modify: `sources/switch/modes/*.mode` (only to add exclusions justified by a recorded failure)

**Interfaces:**
- Consumes: everything above.
- Produces: `BUILD-STATUS.md` — per mode, the first failing module, its error, and the decision taken (fix upstream / exclude / accept).

- [ ] **Step 1: Put the toolchain on PATH for this shell**

```bash
export PATH="/Users/slachiewicz/mvn4/sources/toolchain/current/bin:$PATH"
```

- [ ] **Step 2: Build `mvn3`**

```bash
cd /Users/slachiewicz/mvn4/sources
./mvn-switch mvn3
cd aggregator
mvn -v | head -1
mvn install -DskipTests --fail-at-end 2>&1 | tee /tmp/build-mvn3.log | tail -60
```

Expected: `Apache Maven 3.9.16`. Record every `[ERROR] Failed to execute goal` and the reactor summary's failed modules.

- [ ] **Step 3: Build `mvn4`**

```bash
cd /Users/slachiewicz/mvn4/sources
./mvn-switch mvn4
cd aggregator
mvn -v | head -1
mvn install -DskipTests --fail-at-end 2>&1 | tee /tmp/build-mvn4.log | tail -60
```

Expected: `Apache Maven 4.0.0-rc-5`.

- [ ] **Step 4: Build `mvn4-3xplugins`**

```bash
cd /Users/slachiewicz/mvn4/sources
./mvn-switch mvn4-3xplugins
cd aggregator
mvn install -DskipTests --fail-at-end 2>&1 | tee /tmp/build-mixed.log | tail -60
```

- [ ] **Step 5: Write `BUILD-STATUS.md`**

One section per mode. For each failing module record: module coordinates, the goal that failed, the first three lines of the error, and one of three decisions — `fix-upstream` (with the repository and a one-line description of the change needed), `exclude` (with the mode file line added), or `accept` (why the failure does not block `install -DskipTests`). Extract the failed module list with:

```bash
for f in /tmp/build-mvn3.log /tmp/build-mvn4.log /tmp/build-mixed.log; do
  echo "=== $f ==="
  grep -E '^\[INFO\] .* (FAILURE|SKIPPED) \[' "$f" | head -40
done
```

- [ ] **Step 6: Apply only the justified exclusions and re-verify**

For each `exclude` decision, add the `- <module path>` line to that mode file — and only that mode file — then re-run its build. Every exclusion must have a matching entry in `BUILD-STATUS.md`.

- [ ] **Step 7: Commit**

```bash
cd /Users/slachiewicz/mvn4/sources
git add switch/BUILD-STATUS.md switch/modes/
git commit -m "switch: record per-mode build status and justified exclusions"
```

---

## Self-review

**Spec coverage.** Migration to the master manifest → Tasks 1, 6. Missing aggregator POM trees → Task 7. Mode file format and parser → Tasks 2, 8. Toggling mechanism, including the prose-comment and `<!--<module>` exclusions → Task 3. Runtime selection and the `current` symlink → Tasks 4, 5. `status` subcommand → Task 5. Branch cleanup with archive-first → Task 9. Reality check / build inventory → Task 10. Verification section: `--dry-run` → Task 5 Step 3 and Task 8 Step 5; round trip → Task 8 Step 6; fixture tests → Tasks 2, 3, 9; cleanup baseline diff and recovery proof → Task 9 Steps 5, 6.

**Known gap, deliberate.** `sources/.gitignore` is edited in Task 4 rather than Task 1, so the `toolchain/` directory is untracked only from Task 4 onward. Nothing writes to it before then, so this is safe.

**Type consistency.** `agg_module_state`, `agg_set_module` and `agg_find_pom` keep the same signatures in Tasks 3, 5, 7 and 8. `mode_runtime`/`mode_modules` are consistent across Tasks 2, 5 and 8. `cleanup_classify`/`cleanup_apply`/`cleanup_main` are consistent between Task 9's tests and its implementation, and `cleanup_main` matches the dispatch already written in Task 5. `toolchain_maven_home`/`toolchain_activate`/`toolchain_current` are consistent between Tasks 4 and 5. Exit code 3 means "module not found" in both `agg_module_state` and `agg_find_pom`; `agg_find_pom` adds 4 for "ambiguous".

---

### Task 11: Per-mode git worktrees

Supersedes in-place mode switching, per the decision recorded in DESIGN.md. Task 10's builds run
from these worktrees, so this lands first.

**Files:**
- Create: `switch/lib/worktree.sh`
- Create: `build` (worktree root; committed, identical on every mode branch)
- Modify: `mvn-switch` (add the `worktrees` subcommand)
- Modify: `switch/test/run-tests.sh` (tests above the final `run_all`)

**Interfaces:**
- Consumes: `log_info`/`log_warn`/`die`/`SOURCES_DIR`/`mode_path`/`mode_runtime`/`mode_modules` from `common.sh`; `agg_find_pom`/`agg_module_state`/`agg_set_module` from `aggregator.sh`; `toolchain_maven_home` from `toolchain.sh`.
- Produces:
  - `CHECKOUT_ROOT` — the directory containing `sources/`.
  - `worktree_path MODE` / `worktree_branch MODE`.
  - `worktree_create MODE` — creates the worktree on `mode/<MODE>` with the mode applied and committed.
  - `worktree_verify MODE` — exit 0 when the worktree's committed state matches its mode file.
  - `build_lock_acquire` / `build_lock_release`.
  - `mvn-switch worktrees [--create|--verify|--list]`.

**Two platform facts this task depends on, both verified on this machine:**
- **`flock` does not exist on macOS.** Use an atomic `mkdir` lock; `mkdir` on an existing directory fails here, confirmed. Do not reach for `flock`, `lockfile`, or `shlock`.
- **`exec mvn` would leak the lock**, because `exec` replaces the shell and the `EXIT` trap never fires. Run `mvn` as a child and let the trap release.

- [ ] **Step 1: Write the failing tests**

Append above the final `run_all`:

```bash
. "$LIB_DIR/worktree.sh"

test_worktree_path_is_a_sibling_of_sources() {
  assert_eq "$(dirname "$SOURCES_DIR")/sources-mvn4" "$(worktree_path mvn4)" "worktree path"
}

test_worktree_path_rejects_unknown_mode() {
  local rc
  # The subshell is load-bearing. worktree_path -> mode_path -> die -> exit 1,
  # and an `exit` inside a sourced function is NOT caught by the caller's
  # `&&`/`||` — it terminates the whole test runner, which then silently
  # truncates mid-suite instead of reporting a failure.
  ( worktree_path no-such-mode ) >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "worktree_path must reject an unknown mode"
}

test_worktree_branch_name() {
  assert_eq "mode/mvn4" "$(worktree_branch mvn4)" "branch name"
}

test_build_lock_is_exclusive() {
  local held
  BUILD_LOCK="$TMP_ROOT/lock"
  build_lock_acquire || fail "first acquire must succeed"
  # A second acquirer, simulating another worktree, must be refused while held.
  held="$( BUILD_LOCK="$TMP_ROOT/lock" bash -c '
    . '"$LIB_DIR"'/common.sh; . '"$LIB_DIR"'/worktree.sh
    build_lock_acquire >/dev/null 2>&1 && echo ACQUIRED || echo BLOCKED' )"
  assert_eq "BLOCKED" "$held" "second concurrent build"
  build_lock_release
}

test_build_lock_is_released_and_reacquirable() {
  BUILD_LOCK="$TMP_ROOT/lock2"
  build_lock_acquire || fail "acquire"
  build_lock_release
  build_lock_acquire || fail "must be re-acquirable after release"
  build_lock_release
}

test_stale_lock_steal_admits_exactly_one_winner() {
  # The steal path is where a naive rm -rf + mkdir loses exclusivity: several
  # processes can each conclude the lock is stale and each end up believing
  # they hold it. Race many stealers against one stale lock; exactly one may
  # win. This is probabilistic, so use enough contenders to make a broken
  # implementation fail reliably.
  BUILD_LOCK="$TMP_ROOT/lock4"
  mkdir -p "$BUILD_LOCK"
  echo 999999 > "$BUILD_LOCK/pid"
  : > "$TMP_ROOT/wins"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ( . "$LIB_DIR/common.sh"
      . "$LIB_DIR/worktree.sh"
      BUILD_LOCK="$TMP_ROOT/lock4"
      build_lock_acquire >/dev/null 2>&1 && echo win >> "$TMP_ROOT/wins" ) &
  done
  wait
  assert_eq "1" "$(grep -c win "$TMP_ROOT/wins" 2>/dev/null || echo 0)" "stealers admitted"
}

test_build_lock_steals_a_stale_lock() {
  # A crashed build must not wedge the checkout forever. A lock whose recorded
  # PID is no longer alive is stale and may be taken.
  BUILD_LOCK="$TMP_ROOT/lock3"
  mkdir -p "$BUILD_LOCK"
  echo 999999 > "$BUILD_LOCK/pid"      # a PID that cannot be running
  build_lock_acquire || fail "a stale lock must be stealable"
  build_lock_release
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `bash switch/test/run-tests.sh`
Expected: failure sourcing `switch/lib/worktree.sh` — no such file.

- [ ] **Step 3: Write `switch/lib/worktree.sh`**

```bash
#!/usr/bin/env bash
# <ASF licence header — copy verbatim from switch/lib/common.sh>
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
  # Stale. Claim it atomically. An unconditional `rm -rf` followed by `mkdir`
  # is NOT atomic: two processes can both find the same stale lock, both
  # decide to steal, and the second's `rm -rf` then deletes the directory the
  # first just created — leaving BOTH believing they hold the lock, which is
  # precisely the concurrent build this exists to prevent.
  # `mv` of a directory is atomic, so at most one racer moves the stale lock
  # aside; and the final `mkdir` is the single point that decides the winner,
  # whether or not this process won the rename.
  local stash="$BUILD_LOCK.stale.$$"
  if mv "$BUILD_LOCK" "$stash" 2>/dev/null; then
    rm -rf "$stash"
  fi
  if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
    log_error "lost the race to reclaim a stale build lock; another build won it"
    return 1
  fi
  printf '%s\n' "$$" > "$BUILD_LOCK/pid"
  log_warn "reclaimed a stale build lock from pid ${holder:-unknown}"
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
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `bash switch/test/run-tests.sh`
Expected: every previous test plus the six new ones pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/slachiewicz/mvn4/sources
git add switch/lib/worktree.sh switch/test/run-tests.sh
git commit -m "switch: add worktree resolution and the checkout-wide build lock"
```

- [ ] **Step 6: Write the `build` wrapper**

Create `build` at the repository root, `chmod 755`:

```bash
#!/usr/bin/env bash
# <ASF licence header — copy verbatim from switch/lib/common.sh>
#
# Build this worktree's mode. The directory is the mode: the aggregator state
# is already committed, so there is nothing to switch.
#
#   ./build install -DskipTests
#
# Takes a checkout-wide lock first: every mode drives the same module
# directories and one ~/.m2, so two builds at once corrupt each other silently.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/switch/lib/common.sh"
. "$SELF_DIR/switch/lib/toolchain.sh"
. "$SELF_DIR/switch/lib/worktree.sh"

[ -f "$SELF_DIR/.switch-mode" ] || die "not a mode worktree: no .switch-mode here (run 'mvn-switch worktrees --create')"
MODE="$(cat "$SELF_DIR/.switch-mode")"

runtime="$(mode_runtime "$(mode_path "$MODE")")"
[ -n "$runtime" ] || die "mode '$MODE' has no [runtime] maven value"

build_lock_acquire || exit 1
# NOT `exec`: exec replaces this shell and the EXIT trap never runs, leaking
# the lock and wedging every other worktree until a stale-steal.
trap build_lock_release EXIT

home="$(toolchain_maven_home "$runtime")"
log_info "mode $MODE  ->  $home"
"$home/bin/mvn" "$@"
```

- [ ] **Step 7: Verify the wrapper refuses a concurrent build**

```bash
cd /Users/slachiewicz/mvn4/sources
( . switch/lib/common.sh; . switch/lib/worktree.sh; build_lock_acquire && sleep 5 && build_lock_release ) &
sleep 1
( . switch/lib/common.sh; . switch/lib/worktree.sh; build_lock_acquire && echo "ACQUIRED (BAD)" || echo "BLOCKED (correct)" )
wait
```

Expected: `BLOCKED (correct)`, plus the two explanatory error lines. Then confirm the lock directory is gone afterwards: `ls -d /Users/slachiewicz/mvn4/.mvn-build.lock` must fail.

- [ ] **Step 8: Commit**

```bash
cd /Users/slachiewicz/mvn4/sources
git add build
git commit -m "switch: add the per-worktree build wrapper with a checkout-wide lock"
```
