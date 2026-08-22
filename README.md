# toolkit

A monorepo of per-platform build toolkits. Each platform folder is a self-contained
drop-in build system; projects mount this repo (git submodule at `toolkit/`) and
generate a thin `build.sh` entry via `./build.sh`-style scaffolding.

## Platforms

| Folder | Status | Use |
|---|---|---|---|
| `ios/` | ready | iOS app builds, lint gates, install/watch/test, logs/debug, e2e, TestFlight upload, Sentry queries, screenshots/vision |
| `server/` | ready | Go server builds, start/stop/watch, lint/test, deploy/rollback (Fly.io), migrations, Sentry queries |
| `android/` | planned | — |
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
- `server/config/README.md` — full server toolkit reference

## Vision (shared)

`vision <image> --focus "<question>"` asks a vision model about an image and prints the
answer as text. It lives in `shared/vision.sh` and is wired at the project's root
`build.sh`, speaking an OpenAI-compatible `chat/completions` API.

- `--focus` is required — omitting it prints prompting guidance.
- Images are sent at full resolution by default; `--max-dim N` downsizes on demand.

Environment:

| Env var | Default | Purpose |
|---|---|---|
| `TOOLKIT_MODEL_API_KEY` | — (required) | Provider API key |
| `TOOLKIT_MODEL_BASE_URL` | `https://opencode.ai/zen/go/v1` | Base URL; `/chat/completions` is appended |
| `TOOLKIT_VISION_MODEL` | `deepseek-v4-flash-vision-exp` | Model name for vision queries |

The iOS toolkit adds a `see` command that composes simulator screenshot capture with
`vision` (see `ios/config/README.md`).
