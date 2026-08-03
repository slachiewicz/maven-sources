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
