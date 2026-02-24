# SwiftBar Plugin: Claude Code + Codex Usage

A macOS menu bar plugin that displays your Claude Code and Codex API usage at a glance.

## Screenshot

```
🤖$52.33 🔮$4.52           ← Menu bar
───────────────────────────
🤖 Claude Code (API equivalent)
───────────────────────────
📅 Today: $52.33
📅 Week:  $1,040.17
📅 30d:   $5,012.46
───────────────────────────
📊 Claude Daily Breakdown
  2026-02-24: $52.33 (117.1M tokens)
  2026-02-23: $238.88 (380.9M tokens)
  ...
───────────────────────────
🔮 Codex GPT-5.3 (API equivalent)
───────────────────────────
📅 Today: $4.52 (14.5M tokens)
📅 Week:  $15.37 (46.2M tokens)
📅 30d:   $35.80 (107.5M tokens)
───────────────────────────
📊 Codex Daily Breakdown
  2026-02-24: $4.52 (14.5M tokens)
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

1. Runs 3 parallel `ccusage-mbt` queries (today / 7 days / 30 days)
2. Pipes JSON output through a single Python formatter
3. Splits costs by model name: Claude models vs Codex/GPT models

## Menu Actions

- **Weekly Report**: Opens terminal with detailed 7-day breakdown
- **Monthly Report**: Opens terminal with current month breakdown
- **Session Report**: Opens terminal with per-session usage (Claude only)
- **Refresh**: Force refresh the plugin data
