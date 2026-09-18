# Muse Code

Tracks your Muse Code usage from the session logs already on your Mac — per-day spend
tiles and a usage trend. Muse Code publishes no quota or spend API, so there are no
session/weekly meters: what you see is measured local activity, with dollars estimated
from Meta's published Muse Spark rates.

## What it tracks

| Metric | Meaning |
|---|---|
| Today / Yesterday / Last 30 Days | Local cost and tokens from your Muse sessions |
| Usage Trend | A day-by-day sparkline of tokens over the last month |

There is no plan badge: with no account API, OpenUsage can't tell which Muse plan you're on.

## Where credentials come from

Use Muse Code as usual. OpenUsage never asks for a key: it counts a provider as present
when `META_API_KEY` is exported, when `~/.config/muse/auth.json` exists (written by
`muse login` or `muse auth set`), or when Muse session logs exist on disk. The credential
itself is never read for content and never leaves your Mac — spend comes from the logs,
not from any account.

## The spend tiles

Each assistant step Muse runs appends a `model_completed` event with its token usage to
that session's `session.jsonl`. OpenUsage scans those logs and prices the tokens through
the shared pricing engine: Muse Spark Standard rates ($1.25 per million input tokens,
$4.25 per million output, $0.15 per million cached input tokens), or the discounted
contributor rates ($0.10 / $0.20) when the session's model id carries the `-contributor`
suffix. Reasoning tokens bill as output, matching Meta. Tokens whose model has no known
price still count toward the token totals but carry no dollars, and the tile warns about
the unknown model instead of pricing them at $0.

A period with no recorded local usage reads "No data" rather than a misleading `$0.00`.
No log data leaves your Mac. Subagent transcripts are skipped: their steps are already
mirrored in the parent session's log, so counting both would double-count delegated work.

## Troubleshooting

- **"Muse Code not detected"** — no credential and no session logs were found. Run
  `muse login` and complete at least one Muse session, then refresh.
- **"Couldn't read Muse Code's auth.json"** — the file exists but is unreadable. Check
  its permissions, or run `muse login` again to rewrite it.
- **Spend tiles show "No data"** — OpenUsage needs session logs at
  `~/.local/share/muse/sessions/` (or `$XDG_DATA_HOME/muse/sessions/`). Run a Muse
  session, then refresh. Logs older than 30 days are outside the window.
- **Unknown-model warning on a tile** — the session used a Muse model id with no known
  price (e.g. a newer release than the pricing feed). Tokens still count; dollars appear
  once the pricing feed learns the model.

## Under the hood

Logs: every `session.jsonl` under the sessions directory, parsed incrementally (only
changed files re-parse). `recorded_at` is microseconds since the epoch; usage buckets map
to non-cached input, cache read, cache write, and output plus reasoning. Exact duplicate
steps (mirrored or copied logs) count once.

Spend tiles and trend: `model_completed` usage priced through the shared engine, with the
Muse Spark entries in the pricing supplement (synced hourly to installed apps, no release
needed). The scan is machine-local, so tiles from two Macs sync by sum like the other
local scanners.
