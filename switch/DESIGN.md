# Maven build-mode switcher — design

Date: 2026-08-03
Status: approved (revised after manifest-branch discovery)

## Problem

This is a `repo`-tool checkout of the Apache Maven git repositories, aggregated for a single
build by `sources/aggregator`. The tree needs to build in three configurations, and today there
is no way to move between them.

## Key discovery

`.repo` was initialised against the **`default`** branch of `maven-sources.git`. That branch is
abandoned — its newest commits are "retired components" and "reorganized directories".

The maintained manifest is the **`master`** branch (`sources/default.xml`), whose recent history
reads "core master is now 4.1, 4.0.x is another active maintenance branch", "3.x is now 3.10
with Resolver 2 like Maven 4", "Shared GH Actions: main and v4 branches".

The `master` manifest already separates the two lines **by directory**, checking both out side
by side:

| Path | Repository | Revision |
|---|---|---|
| `core/maven` | `maven.git` | `master` (4.1.0-SNAPSHOT) |
| `core/maven-4.0.x` | `maven.git` | `maven-4.0.x` (4.0.0-SNAPSHOT) |
| `core/3.x/maven-3` | `maven.git` | `maven-3.10.x` |
| `core/3.x/mvnd-1` | `maven-mvnd.git` | `mvnd-1.x` |
| `core/3.x/its-3` | `maven-integration-testing.git` | `maven-3.10.x` |
| `plugins/core/*` | clean, compiler, deploy, install, resources | `maven-*-plugin-3.x` |
| `plugins/core-4/*` | same five repositories | `master` (Maven 4 native) |
| `plugins/packaging/{jar,source}` | | `maven-*-plugin-3.x` |
| `plugins/packaging-4/{jar,source}` | same two repositories | `master` |
| `shared/{archiver,filtering}` | | `maven-*-3.x` |
| `shared-4/{archiver,filtering}` | same two repositories | `master` |

This is precisely what the aggregator's existing commented-out candidates refer to:
`<!--module>../../../core/maven-4.0.x</module-->`, `<!--module>3.x</module-->`,
`<!--module>core-4</module-->`, `<!--module>packaging-4</module-->`,
`<!--module>shared-4</module-->`. They are not dead remnants of an abandoned scheme — the scheme
is live upstream and only the matching aggregator POM trees were never written.

## Consequence for the design

Because both lines are on disk simultaneously, **no branch switching is required**. Switching a
mode reduces to toggling `<module>` entries in the aggregator POMs. This removes the guarded-switch
machinery, removes all risk to the 136 local branches that carry local-only commits, and keeps
the tree aligned with upstream.

## Goal

| Mode | Runtime | Core | Plugin/shared trees |
|---|---|---|---|
| `mvn3` | Maven 3.9.16 (system) | `core/3.x/*` | `plugins/core`, `plugins/packaging`, `shared` |
| `mvn4` | Maven 4.0.0-rc-5 | `core/maven-4.0.x` | `plugins/core-4`, `plugins/packaging-4`, `shared-4` (+ the reporting/tools plugins, which have no 4-native line) |
| `mvn4-3xplugins` | Maven 4.0.0-rc-5 | `core/maven-4.0.x` | `plugins/core`, `plugins/packaging`, `shared` |

In each, `cd sources/aggregator && mvn install -DskipTests` should build the tree.

Note that `plugins/core-4` covers only five of the eight modules in `plugins/core`; site,
surefire and verifier have no 4-native line and stay active in every mode. Toggling is therefore
per-module, not per-tree.

## Scope

The switcher may change **only** which `<module>` entries are active in
`sources/aggregator/**/pom.xml`. It never edits an individual repository's POM and never moves a
git branch.

Non-goals: rewriting `mavenVersion` or parent versions; building Maven from source to obtain a
runtime; guaranteeing a green build by itself (see "Reality check").

## Migration to the master manifest

A prerequisite, done once, and irreversible enough to need a safety net.

Comparing `default` → `master`: **15 projects appear**, **17 disappear**, and two are path moves
of a repository that stays (`core/maven-3` → `core/3.x/maven-3` with revision `maven-3.9.x` →
`maven-3.10.x`; `misc/gh-actions-shared` → `misc/gh-actions-shared/{main,v4}`).

Five of the disappearing/moving paths carry commits that exist on no remote:

| Path | Local-only branches |
|---|---|
| `core/maven-3` | `copilot/mng-11011-settings-interpolation`, `plexus`, `mng-7266-remove-maven-compat`, one dependabot |
| `misc/gh-actions-shared` | `include-option` |
| `plexus/components/cipher` | `junit5` |
| `plexus/plexus-containers` | `wip`, one dependabot |
| `shared/artifact-transfer` | one dependabot |

`repo` removes obsolete project directories, and refs live in `.repo/projects/<path>.git`, keyed
by path — so a path that disappears takes its refs with it. Before re-init, every repository is
bundled with `git bundle create --all` into `~/mvn4-archive/`, **outside the checkout**, so
nothing depends on `.repo` surviving.

Also dropped by the master manifest, with no local-only work: `core/its`,
`doxia/tools/{doxia-book-maven-plugin,doxia-book-renderer,linkcheck}`, `misc/skins/default`,
`plexus/components/{cli,digest,swizzle}`, `plexus/pom/components`,
`plugins/reporting/maven-linkcheck-plugin`, `plugins/tools/maven-pdf-plugin`,
`shared/project-utils`.

The five `plugins/core/*`, two `plugins/packaging/*` and two `shared/*` projects keep their paths
but change revision from `master` to their `-3.x` line. Their local branches survive untouched.

## Layout

Everything lives inside `sources/` (`maven-sources.git`), which owns both the aggregator and
`default.xml`, so it is upstreamable.

```
sources/
  mvn-switch                    # entry point (bash; needs git, curl, tar, shasum)
  switch/
    DESIGN.md                   # this file
    PLAN.md                     # implementation plan
    lib/common.sh               # logging, mode-file parser, path resolution
    lib/aggregator.sh           # <module> line toggling
    lib/toolchain.sh            # Maven distribution download, verify, `current` symlink
    lib/cleanup.sh              # local-branch triage
    modes/mvn3.mode
    modes/mvn4.mode
    modes/mvn4-3xplugins.mode
    migrate/archive-all.sh      # one-shot pre-migration safety net
    migrate/verify-migration.sh # one-shot post-migration assertion
    test/run-tests.sh           # plain-bash tests over fixture POMs
    test/fixtures/              # small POMs exercising the toggler
    BUILD-STATUS.md             # per-mode failure inventory (written by Task 10)
  toolchain/                    # gitignored: Maven distributions + `current` symlink
```

`sources/.gitignore` gains `/toolchain/`, `/switch/cleanup-report.md` and `/.switch-state`.

## Missing aggregator POM trees

The master manifest's directories have no aggregator POMs. Four must be written, each a `pom`
packaging module parented to the tree it belongs to:

- `aggregator/core/3.x/pom.xml` — `core/3.x/{maven-3,mvnd-1,its-3}`
- `aggregator/plugins/core-4/pom.xml` — the five 4-native core plugins
- `aggregator/plugins/packaging-4/pom.xml` — jar, source
- `aggregator/shared-4/pom.xml` — archiver, filtering

Their parents' existing commented candidates (`3.x`, `core-4`, `packaging-4`, `shared-4`,
`../../../core/maven-4.0.x`) then become live, toggleable entries.

## Mode file format

Plain INI-ish text, parsed with `case`/`read` — no external dependency.

```ini
# modes/mvn4.mode
[runtime]
maven = 4.0.0-rc-5

[modules]
# + activate, - comment out
- ../../../core/maven
+ ../../../core/maven-4.0.x
- 3.x
- ../../../../plugins/core/maven-clean-plugin
+ core-4
```

`[runtime] maven = system` selects the `mvn` already on `PATH`; `mvn3.mode` uses it to pick up
Homebrew's 3.9.16 without downloading anything.

Every module path named in any mode file must exist as a candidate line in some aggregator POM;
the parser fails fast otherwise. Each mode file names **every** toggleable module explicitly, so
a mode is a complete description rather than a delta — switching between any two modes is then
order-independent.

## Toggling mechanism

Line-based, deliberately not an XML parse. A candidate module appears in exactly one of two
forms, and the script flips between them, preserving indentation:

```xml
    <module>../../../core/maven-4.0.x</module>
    <!--module>../../../core/maven-4.0.x</module-->
```

Idempotent, minimal `git diff`, no reformatting of surrounding XML.

The form with a space — `<!-- misc/plugin-testing merged into apache/maven core -->` in
`aggregator/misc/pom.xml`, and `<!--<module>...</module>-->` in `aggregator/svn/pom.xml` — is
deliberately **not** matched. Those are prose comments and permanently-disabled modules, not
mode-dependent candidates.

## Runtime selection

`sources/toolchain/current` is a symlink re-pointed on every switch. The user adds one stable
entry to `PATH`, once:

```sh
export PATH="$HOME/mvn4/sources/toolchain/current/bin:$PATH"
```

Thereafter plain `mvn` in `sources/aggregator` uses whichever runtime the active mode selected;
Maven's launcher resolves its home through the symlinked directory correctly.

- `mvn3` → the system Maven home (`/opt/homebrew/Cellar/maven/3.9.16/libexec`).
- `mvn4`, `mvn4-3xplugins` → `toolchain/apache-maven-4.0.0-rc-5`, downloaded from
  `dlcdn.apache.org` (falling back to `archive.apache.org`) and verified against the published
  `.sha512` before use.

`./mvn-switch status` prints the active mode, the resolved `mvn -v`, and any module whose
active/commented state disagrees with the active mode.

## Branch cleanup

`./mvn-switch cleanup [--apply]` — a separate subcommand that never runs as part of a switch.
`--dry-run` is the default.

Measured before migration: 354 local branches, 136 with a tip reachable from no remote ref,
6 repositories on detached HEAD, 0 with uncommitted changes.

1. **Archive first** — `git tag archive/<sanitized-branch>` for every local branch, so no commit
   becomes unreachable and nothing depends on reflog expiry. Archive tags stay out of
   `git branch` output.
2. **Delete redundant** — tip contained in some `refs/remotes/**` ref. ~218 branches.
3. **Delete stale dependabot** — matches `dependabot/*` and `origin/<same name>` no longer
   exists, so the PR was merged or closed. Deleted even when carrying local commits, because
   step 1 archived it. ~40 branches.
4. **Never touched** — the current branch and any local-only work outside `dependabot/*`.
   ~96 branches.
5. **Report** — `switch/cleanup-report.md` lists every kept branch with repository, SHA,
   commits-ahead, last commit date and subject, plus where each detached HEAD pointed.

Classification uses `git branch -r --contains <sha>`, not an ahead-count against `origin/HEAD`;
a branch cut from a 3.x line is otherwise misreported as local-only.

## Reality check

The mode switching is deterministic and fully deliverable. Making `mvn install -DskipTests` pass
across 400+ modules is empirical and is **not** guaranteed by this design. The plan builds each
mode, reports exactly what fails, and decides fix-versus-exclude case by case. Per-mode module
exclusions are expected to grow. Some failures will need source changes upstream, outside the
scope of a switcher.

Known facts to keep in view:

- Maven 4.0.0 GA is not released; `4.0.0-rc-5` is the newest published version and is what the
  4-native plugins target (`mavenVersion` `4.0.0-rc-4`/`rc-5`).
- Local branch names in this tree are not trustworthy — `core/maven`'s local `maven-4.0.x`
  tracks `origin/master` and carries `4.1.0-SNAPSHOT`. After migration the *manifest* supplies
  `core/maven-4.0.x` as a separate directory, so this stops mattering.
- `sources` is one commit ahead of `origin/master` (`e93a253`, removing the
  `misc/plugin-testing` module).
- `plugins/core/surefire-mockito-openrewrite` exists on disk but is in neither manifest branch
  and no aggregator module. It is left alone.
- The aggregator's `sisu` module is commented out upstream as "failing for unknown reason", and
  `studies` sits behind a profile. Both stay as they are, in every mode.
- The `origin/mvn4` branches present in nearly every Maven repository date from January 2022
  (the alpha-1 era) and are unusable.

## Verification

- `--dry-run` on each mode, reviewed before any write.
- Round trip: `mvn3 → mvn4 → mvn3` reproduces a byte-identical aggregator tree, proving
  idempotence and order-independence.
- `switch/test/run-tests.sh` exercises the toggler and mode parser against fixture POMs, with no
  dependency on the real checkout.
- `cleanup --dry-run` output is diffed against the measured baseline before `--apply` is run,
  and every archived branch is confirmed recoverable from its archive tag afterwards.
