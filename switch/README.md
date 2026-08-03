# Building this checkout in three Maven configurations

This tree holds the Maven 3.x and Maven 4 lines side by side. Each build configuration
("mode") has its own git worktree, so **the directory is the mode** — nothing to switch,
nothing left dirty.

## Everyday use

```sh
cd ~/mvn4/sources-mvn3            # or sources-mvn4, sources-mvn4-3xplugins
./build install -DskipTests
```

`./build` picks the right Maven for that mode, runs it from `aggregator/`, and takes a
checkout-wide lock. Everything after `./build` is passed straight through to Maven, so
`./build install -DskipTests --fail-at-end -pl :maven-clean-plugin` works as you'd expect.

| Directory | Core | Plugins / shared | Maven |
|---|---|---|---|
| `sources-mvn3` | `core/3.x/*` (3.10.0-SNAPSHOT) | 3.x lines | system 3.9.16 |
| `sources-mvn4` | `core/maven-4.0.x` (4.0.0-SNAPSHOT) | `-4` lines | 4.0.0-rc-6 |
| `sources-mvn4-3xplugins` | `core/maven-4.0.x` | 3.x lines | 4.0.0-rc-6 |

`sources/` itself is the development tree. It carries the tooling and has **no mode applied** —
don't build there.

## Switching modes

Just `cd` to a different directory. But the three modes share the module directories under
`~/mvn4/` and one `~/.m2`, so clean before you switch:

```sh
cd ~/mvn4/sources-mvn3 && ./build clean
cd ~/mvn4/sources-mvn4 && ./build install -DskipTests
```

**Never build two modes at once.** They write the same `target/` trees and install the same
GAVs over each other — it corrupts silently rather than failing. `./build` refuses to start
while another build holds the lock, but that guard is advisory: it reliably catches a second
build started while one is running, and does not try to be a bulletproof mutex. See DESIGN.md
for why.

## Plain `mvn` instead of `./build`

Works, but you lose the lock and must pick the Maven yourself:

```sh
cd ~/mvn4/sources-mvn4/aggregator
../toolchain/current/bin/mvn install -DskipTests
```

## Checking state

```sh
cd ~/mvn4/sources-mvn4
./mvn-switch status        # active mode, resolved mvn -v, and any drift
```

`status` is the safety net for the one thing that can go wrong: a mode worktree whose
aggregator POMs no longer match its mode file (someone edited them, or a `git checkout`
reverted them). It reports each module that is in the wrong state.

## Keeping the modes current

An upstream change to an aggregator POM — a module added or removed — has to reach all three
mode branches. They are ordinary branches off `mvn-switch-tooling`:

```sh
cd ~/mvn4/sources-mvn3
git rebase mvn-switch-tooling
./mvn-switch status        # confirm the mode still applies cleanly
```

This is the standing cost of the layout. `status` is what turns silent drift into a visible
failure, so run it after any rebase.

## The development tree

`sources/` is where the tooling itself is worked on.

```sh
cd ~/mvn4/sources
bash switch/test/run-tests.sh     # 38 tests, no Maven needed
./mvn-switch list                 # available modes and their runtimes
./mvn-switch mvn4 --dry-run       # what a mode would change, writes nothing
```

`./mvn-switch <mode>` also applies a mode in place here, which is how the mode branches were
built. It leaves the tree dirty by design — that is why the worktrees exist.

## Branch cleanup

```sh
./mvn-switch cleanup               # dry run: classify, write a report, change nothing
./mvn-switch cleanup --apply       # archive every branch as a tag, delete the disposable ones
```

Every branch is tagged `archive/<name>` before anything is deleted, so a deletion is always
reversible:

```sh
git checkout -b <name> archive/<name>
```

Branches carrying commits that exist on no remote are **kept**, including `dependabot/*`
branches that someone committed real work onto. `switch/cleanup-report.md` lists what was kept
and what was deleted.

## Recovering from the archive

Before the manifest migration, every repository was bundled to `~/mvn4-archive/`. Those bundles
still hold branches that the migration dropped from the checkout — notably `core/maven-3`,
which is no longer a project:

```sh
git clone --mirror ~/mvn4-archive/core_maven-3.bundle /tmp/recover
git -C /tmp/recover log --oneline copilot/mng-11011-settings-interpolation
```

Use `--mirror`. A plain clone remaps non-default branches to `refs/remotes/origin/*`, which
makes a perfectly good bundle look empty.
