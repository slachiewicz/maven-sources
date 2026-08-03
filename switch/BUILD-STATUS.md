# Per-mode build status

What `./build install -DskipTests --fail-at-end` actually does in each mode. This is an
inventory, not a promise — it records what failed and what was decided about it.

## mvn3 — 2026-08-03

Maven 3.9.16 (system), `sources-mvn3`, cold build (no `target/`, warm `~/.m2`).

| | |
|---|---|
| Result | **BUILD FAILURE** |
| Wall clock | 16:49 |
| Modules in reactor | 345 |
| SUCCESS | **328** |
| FAILURE | 5 |
| SKIPPED | 12 (all collateral — wagon providers blocked by `wagon-provider-test`) |

**Every failure is the same goal and the same rule**:
`maven-enforcer-plugin:3.6.3:enforce (drop-legacy-dependencies)` →
`BannedDependencies`. Nothing else in the reactor failed.

The rule bans Maven-3.0-era and legacy Plexus artifacts. These five modules still pull them,
directly or transitively:

| Module | Banned artifact | Reached via |
|---|---|---|
| `wagon-provider-test` | `plexus-container-default:2.1.1` | direct |
| `wagon-tck-http` | `plexus-container-default:2.1.1` | direct |
| `maven-ear-plugin` | `maven-core:3.0` | `maven-mapping:3.0.0` |
| `maven-changelog-plugin` | `maven-plugin-api:3.1.0`, `maven-core:3.1.0` | `maven-reporting-impl:3.1.0` |
| `maven-scm-publish-plugin` | `plexus-container-default:1.0-alpha-9-stable-1` | `plexus-archiver:2.2` |

### Decision: fix-upstream, not exclude

These are genuine defects in the modules themselves — each declares a dependency its own
parent POM forbids. They are not artifacts of the mode switcher, of the manifest migration, or
of the aggregator: the switcher's only effect is which `<module>` lines are active, and these
five are active in every mode.

Excluding them would hide a real problem and silently shrink the reactor. Each needs a
dependency bump in its own repository:

- `misc/wagon` — drop or update `plexus-container-default` in `wagon-provider-test` and
  `wagon-tck-http`.
- `plugins/packaging/maven-ear-plugin` — update `maven-mapping` past 3.0.0, which drags in
  `maven-core:3.0`.
- `plugins/reporting/maven-changelog-plugin` — update `maven-reporting-impl` past 3.1.0.
- `plugins/tools/maven-scm-publish-plugin` — update `plexus-archiver` past 2.2.

The 12 SKIPPED wagon modules are collateral: they are downstream of `wagon-provider-test` and
were never attempted. Fixing that one module should recover all 12.

### Reproducing

```sh
cd ~/mvn5/sources-mvn3
./build install -DskipTests --fail-at-end
```

`--fail-at-end` matters. Without it the reactor stops at `wagon-provider-test` and the other
four failures stay hidden behind it.

## mvn4 — not yet run

## mvn4-3xplugins — not yet run

Both need disk headroom: the `mvn3` run above regenerated ~200 `target/` trees. Clean between
modes — they share module directories and one `~/.m2`.
