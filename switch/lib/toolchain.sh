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
