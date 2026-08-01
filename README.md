# toolkit

A monorepo of per-platform build toolkits. Each platform folder is a self-contained
drop-in build system; projects mount this repo (git submodule at `toolkit/`) and
generate a thin `build.sh` entry via `./build.sh`-style scaffolding.

## Platforms

| Folder | Status | Use |
|---|---|---|
| `ios/` | ready | iOS app builds, lint gates, install/watch/test, logs/debug, e2e, TestFlight upload, Sentry queries |
| `android/` | planned | — |
| `go/` | planned | server tooling |
| `web/` | planned | — |

## Adding the toolkit to a project

```
toolkit/install.sh <project-dir>
```

`install.sh` inspects the project, confirms the detected platforms, mounts this repo
as a git submodule at `toolkit/`, generates the project `build.sh` (a thin entry for
single-platform projects, a dispatcher for multi-platform ones), seeds
`build.properties` + lint/format configs when missing, and runs each platform's
`setup`. Both `install` and `setup` are idempotent — re-running only does what changed.

External services (Sentry, TestFlight upload, e2e, local server) are enabled
per-project via the platform's `./build.sh configure`.

## Per-platform docs

- `ios/config/README.md` — full iOS toolkit reference
