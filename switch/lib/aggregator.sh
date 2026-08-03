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

  tmp="$(mktemp)"
  awk -v mod="$mod" -v want="$want" '
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
  ' "$pom" > "$tmp"

  mv "$tmp" "$pom"
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
