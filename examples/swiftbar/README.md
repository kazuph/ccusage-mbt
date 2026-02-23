# SwiftBar Plugin: Claude Code + Codex Usage

A macOS menu bar plugin that displays your Claude Code and Codex API usage at a glance.

## Screenshot

```
🤖$632.91 🔮$3.66          ← Menu bar
───────────────────────────
🤖 Claude Code (API equivalent)
───────────────────────────
📅 Today: $632.91
📅 Week:  $2569.39
📅 30d:   $13725.40
───────────────────────────
📊 Claude Daily Breakdown
  2026-02-23: $632.91 (325.5M tokens)
  2026-02-22: $101.27 (52.3M tokens)
  ...
───────────────────────────
🔮 Codex GPT-5.3 (API equivalent)
───────────────────────────
📅 Today: $3.66 (8.9M tokens)
📅 Week:  $176.73 (530.3M tokens)
📅 30d:   $437.37 (1.6B tokens)
───────────────────────────
📊 Codex Daily Breakdown
  2026-02-23: $3.66 (8.9M tokens)
  ...
```

## Prerequisites

1. [SwiftBar](https://github.com/swiftbar/SwiftBar) installed
2. `ccusage-mbt` binary in `~/.local/bin/` (see [main README](../../README.md))
3. Python 3 (for output formatting)

## Installation

1. Copy `ccusage.1h.sh` to your SwiftBar plugin directory:

```bash
cp ccusage.1h.sh ~/Library/Application\ Support/SwiftBar/Plugins/
chmod +x ~/Library/Application\ Support/SwiftBar/Plugins/ccusage.1h.sh
```

2. SwiftBar will automatically pick it up and refresh every hour (`.1h.` in filename).

## How It Works

1. Runs 3 parallel `ccusage-mbt` queries (today / 7 days / 30 days) with `--source all`
2. Pipes JSON output through a single Python formatter
3. Splits costs by model name: Claude models vs Codex/GPT models
4. Caches output for 55 minutes to avoid redundant computation
5. Background refresh when cache expires (stale data shown while refreshing)

## Menu Actions

- **Weekly Report**: Opens terminal with detailed 7-day breakdown
- **Monthly Report**: Opens terminal with current month breakdown
- **Session Report**: Opens terminal with per-session usage (Claude only)
- **Refresh**: Force refresh the plugin data
