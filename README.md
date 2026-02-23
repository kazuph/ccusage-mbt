# ccusage-mbt

A blazing-fast CLI tool to aggregate Claude Code and Codex (OpenAI) API usage from local JSONL logs. Written in [MoonBit](https://www.moonbitlang.com/) with C FFI for maximum performance.

## Why?

Claude Code and Codex store API interaction logs as JSONL files locally. Aggregating usage across thousands of sessions (4.7GB+ of Claude data, 600MB+ of Codex data) is painfully slow with interpreted languages.

`ccusage-mbt` solves this by:
- Parsing JSONL at the C level using `strstr()` — no full JSON parse, no UTF-16 conversion
- Deduplicating entries with an FNV-1a hash set in C
- Reading Codex sessions via tail-read (only the last entry matters)
- Filtering at the directory level before opening files

## Benchmarks

Measured on MacBook Pro (M3 Max, 128GB RAM) with ~9,100 Claude JSONL files (4.7GB) and ~300 Codex JSONL files (667MB):

| Query | Time | Data Processed |
|-------|------|----------------|
| Today (Claude + Codex) | **0.3s** | ~300MB |
| 7 days (Claude + Codex) | **0.7s** | ~1.9B tokens |
| 30 days (Claude + Codex) | **4.4s** | ~8.5B tokens |

Previously, the 30-day query took **1 minute 42 seconds** with the Node.js implementation (`ccusage`). That's an **~23x speedup**.

### Binary Size

The compiled native binary is only **460KB**.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    ccusage-mbt CLI                       │
│                   (MoonBit main.mbt)                     │
│                                                         │
│  Subcommands: daily | monthly | weekly | session        │
│  Flags: --since, --until, --source, --json, --breakdown │
├─────────────────────────────────────────────────────────┤
│              MoonBit Application Layer                   │
│                                                         │
│  - CLI argument parsing                                 │
│  - Date range computation                               │
│  - Cost calculation (Claude & Codex pricing models)     │
│  - Output formatting (table / JSON)                     │
│  - Directory traversal & file discovery                 │
├─────────────────────────────────────────────────────────┤
│            C FFI Layer (native_helper.c)                 │
│                                                         │
│  Fast Claude Parser:                                    │
│  ┌───────────────────────────────────────┐              │
│  │ c_fast_read_claude(since, until)      │              │
│  │  - fgets() line reader                │              │
│  │  - strstr() field extraction          │              │
│  │  - FNV-1a hash dedup (256K slots)     │              │
│  │  - Pre-filter: skip lines without     │              │
│  │    "input_tokens"                     │              │
│  │  - Extract from "usage" position      │              │
│  │    (avoids false matches in content)  │              │
│  └───────────────────────────────────────┘              │
│                                                         │
│  Codex Tail Reader:                                     │
│  ┌───────────────────────────────────────┐              │
│  │ c_read_codex_session(path)            │              │
│  │  - Progressive tail-read              │              │
│  │    (64KB → 256KB → full file)         │              │
│  │  - Find last "token_count" entry      │              │
│  │  - Cumulative values → session total  │              │
│  └───────────────────────────────────────┘              │
│                                                         │
│  Utilities:                                             │
│  - UTC→local timezone conversion                        │
│  - File mtime extraction                                │
│  - String substring (zero-copy)                         │
├─────────────────────────────────────────────────────────┤
│                   Data Sources                           │
│                                                         │
│  Claude Code:                                           │
│  ~/.claude/projects/**/*.jsonl                          │
│  - Each line = individual API response                  │
│  - Fields: message.usage.{input,output,cache_*}_tokens  │
│  - Dedup by message.id + requestId                      │
│                                                         │
│  Codex (OpenAI):                                        │
│  ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl           │
│  - token_count entries with cumulative totals           │
│  - Directory path = local date (no conversion needed)   │
│  - Last entry = session total                           │
└─────────────────────────────────────────────────────────┘
```

### Why MoonBit + C FFI?

MoonBit compiles to native code and provides a clean FFI boundary with C. This architecture lets us:

1. **Keep business logic in MoonBit** — type-safe, pattern matching, immutable data structures for cost calculation and output formatting
2. **Push hot paths to C** — `strstr()` on raw bytes is orders of magnitude faster than parsing full JSON and converting to UTF-16
3. **Zero-copy where possible** — the C layer extracts integers directly from the byte stream without allocating intermediate strings

The key insight: we don't need to parse the full JSON structure. We only need 6 fields (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `model`, `message.id`), and `strstr()` finds them in O(n) without any allocation.

### Deduplication Strategy

Claude Code JSONL files can contain duplicate entries (same API response logged multiple times). We deduplicate using:

- **FNV-1a hash** of `message.id` + `requestId` concatenation
- **256K-slot hash table** (~3MB memory) with linear probing
- Implemented entirely in C for zero MoonBit ↔ C boundary crossings during dedup checks

### Codex Tail-Read Optimization

Codex JSONL files contain cumulative token counts — the last `token_count` entry holds the session total. Instead of reading the entire file:

1. Seek to `file_size - 64KB`
2. Scan backward for last `token_count`
3. If not found, try `file_size - 256KB`
4. Fall back to full read only if necessary

This turns a sequential scan into a near-constant-time operation for most session files.

## Installation

### Prerequisites

- [MoonBit toolchain](https://www.moonbitlang.com/download/)
- C compiler (included with Xcode on macOS)

### Build

```bash
git clone https://github.com/kazuph/ccusage-mbt.git
cd ccusage-mbt
moon build --target native
cp _build/native/debug/build/cmd/main/main.exe ~/.local/bin/ccusage-mbt
```

## Usage

```bash
# Today's usage (Claude + Codex combined)
ccusage-mbt daily --since 20260223 --until 20260223

# Last 7 days
ccusage-mbt daily --since 20260216

# Last 30 days
ccusage-mbt daily --since 20260124

# Claude only
ccusage-mbt daily --since 20260223 --source claude

# Codex only
ccusage-mbt daily --since 20260223 --source codex

# JSON output (for scripting)
ccusage-mbt daily --json --since 20260223

# With model breakdown
ccusage-mbt daily --since 20260223 --breakdown

# Monthly aggregation
ccusage-mbt monthly --since 20260101

# Weekly aggregation
ccusage-mbt weekly --since 20260101

# Per-session breakdown
ccusage-mbt session --since 20260223
```

### Output Example

```
        Date |        Input |       Output |   Cache Create |     Cache Read |   Total Tokens |         Cost
-------------+--------------+--------------+----------------+----------------+----------------+--------------
  2026-02-21 |       19,825 |       10,472 |      3,545,393 |     55,786,897 |     59,362,587 |      $104.34
  2026-02-22 |       16,879 |       13,992 |      1,968,355 |     50,299,365 |     52,298,591 |      $101.27
  2026-02-23 |    1,368,905 |      310,997 |      9,830,638 |    323,801,567 |    335,312,107 |      $638.12
-------------+--------------+--------------+----------------+----------------+----------------+--------------
       Total |    1,405,609 |      335,461 |     15,344,386 |    429,887,829 |    446,973,285 |      $843.73
```

### JSON Output

```bash
ccusage-mbt daily --json --since 20260223 --until 20260223
```

```json
{
  "daily": [
    {
      "date": "2026-02-23",
      "inputTokens": 1368905,
      "outputTokens": 310997,
      "cacheCreationTokens": 9830638,
      "cacheReadTokens": 323801567,
      "totalTokens": 335312107,
      "totalCost": 638.12,
      "modelsUsed": ["claude-opus-4-6", "claude-haiku-4-5-20251001", "gpt-5.3-codex"],
      "modelBreakdowns": [...]
    }
  ],
  "totals": { ... }
}
```

## Pricing Models

### Claude Code (Standard)

| Model | Input | Output | Cache Creation | Cache Read |
|-------|-------|--------|----------------|------------|
| claude-opus-4, opus-4-1 | $15.00/M | $75.00/M | $18.75/M | $1.50/M |
| claude-opus-4-5 | $5.00/M | $25.00/M | $6.25/M | $0.50/M |
| claude-opus-4-6 | $5.00/M | $25.00/M | $6.25/M | $0.50/M |
| claude-sonnet-4/4-5/4-6 | $3.00/M | $15.00/M | $3.75/M | $0.30/M |
| claude-haiku-4-5 | $1.00/M | $5.00/M | $1.25/M | $0.10/M |

### Claude Code (Tiered — 200K+ tokens per request)

| Model | Input | Output | Cache Creation | Cache Read |
|-------|-------|--------|----------------|------------|
| claude-opus-4-6 | $10.00/M | $37.50/M | $12.50/M | $1.00/M |
| claude-sonnet-4/4-5/4-6 | $6.00/M | $22.50/M | $7.50/M | $0.60/M |

### Codex (API Equivalent)

| Model | Input | Cached Input | Output + Reasoning |
|-------|-------|--------------|-------------------|
| gpt-5.3-codex | $1.25/M | $0.125/M | $10.00/M |

## SwiftBar Integration

A ready-to-use [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin is included in `examples/swiftbar/`. It displays your Claude Code and Codex usage directly in the macOS menu bar.

See [examples/swiftbar/README.md](examples/swiftbar/README.md) for setup instructions.

## Project Structure

```
ccusage-mbt/
├── cmd/main/
│   ├── main.mbt          # MoonBit application (964 lines)
│   ├── native_helper.c   # C FFI layer (408 lines)
│   └── moon.pkg          # Package config
├── examples/
│   └── swiftbar/
│       ├── ccusage.1h.sh  # SwiftBar plugin
│       └── README.md      # Setup instructions
├── moon.mod.json          # Module metadata
└── README.md
```

Total: ~1,400 lines of code for a tool that processes 5GB+ of data in under 5 seconds.

## License

MIT
