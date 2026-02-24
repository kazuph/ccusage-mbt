#!/bin/bash

# <xbar.title>Claude Code Usage</xbar.title>
# <xbar.version>v6.0</xbar.version>
# <xbar.author>kazuph</xbar.author>
# <xbar.author.github>kazuph</xbar.author.github>
# <xbar.desc>Display Claude Code + Codex daily usage (ccusage-mbt unified)</xbar.desc>
# <xbar.dependencies>ccusage-mbt</xbar.dependencies>

# PATH setup
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# ============================================================
# Handle menu item clicks (terminal reports)
# ============================================================
if [ -n "$1" ]; then
    case "$1" in
        weekly)
            echo "=== This Week's Claude Code + Codex Usage (API equivalent) ==="
            WEEK_START=$(date -v-7d +"%Y%m%d" 2>/dev/null || date +"%Y%m%d")
            ccusage-mbt daily --since "$WEEK_START" --breakdown
            echo ""; echo "Press any key to close..."; read -n 1 ;;
        monthly)
            echo "=== This Month's Claude Code + Codex Usage (API equivalent) ==="
            ccusage-mbt daily --since "$(date +%Y%m01)" --breakdown
            echo ""; echo "Press any key to close..."; read -n 1 ;;
        session)
            echo "=== Session Usage Report (API equivalent) ==="
            echo "(scanning all sessions - this may take a minute...)"
            echo ""
            THIRTY_DAYS_AGO=$(date -v-30d +"%Y%m%d" 2>/dev/null || date +"%Y%m%d")
            ccusage-mbt session --since "$THIRTY_DAYS_AGO" --source claude
            echo ""; echo "Press any key to close..."; read -n 1 ;;
    esac
    exit 0
fi

# ============================================================
# Python setup
# ============================================================
UV_PYTHON_CMD=()
if command -v uv >/dev/null 2>&1; then
    UV_PYTHON_CMD=(uv run python3)
elif command -v python3 >/dev/null 2>&1; then
    UV_PYTHON_CMD=(python3)
fi

if [ ${#UV_PYTHON_CMD[@]} -eq 0 ]; then
    echo "🤖 CC Usage (Error)"
    echo "---"
    echo "❌ Error: python3 not found"
    echo "🔄 Refresh | refresh=true"
    exit 0
fi

run_uv_python() { "${UV_PYTHON_CMD[@]}" "$@"; }

# Check ccusage-mbt
if ! command -v ccusage-mbt &>/dev/null; then
    echo "🤖 CC Usage (Error)"
    echo "---"
    echo "❌ ccusage-mbt not found"
    echo "🔄 Refresh | refresh=true"
    exit 0
fi

# Date ranges
TODAY=$(date +"%Y%m%d")
WEEK_START=$(date -v-7d +"%Y%m%d" 2>/dev/null || date +"%Y%m%d")
THIRTY_DAYS_AGO=$(date -v-30d +"%Y%m%d" 2>/dev/null || date +"%Y%m%d")

# ============================================================
# Parallel Data Fetching (all via ccusage-mbt, Claude+Codex unified)
# ============================================================
TMPD=$(mktemp -d)

ccusage-mbt daily --json --since "$TODAY" --until "$TODAY" > "$TMPD/today" 2>/dev/null &
ccusage-mbt daily --json --since "$WEEK_START" > "$TMPD/weekly" 2>/dev/null &
ccusage-mbt daily --json --since "$THIRTY_DAYS_AGO" > "$TMPD/monthly" 2>/dev/null &

wait

DATA_TODAY=$(< "$TMPD/today")
DATA_WEEKLY=$(< "$TMPD/weekly")
DATA_MONTHLY=$(< "$TMPD/monthly")

/bin/rm -rf "$TMPD"

# Check if we got valid data
if [ -z "$DATA_TODAY" ] || [ "$(echo "$DATA_TODAY" | head -c1)" != "{" ]; then
    echo "🤖 Error"
    echo "---"
    echo "❌ Failed to fetch data"
    echo "🔄 Refresh | refresh=true"
    exit 0
fi

# ============================================================
# Generate Output (single Python call for all formatting)
# ============================================================
printf '%s\n---SEP---\n%s\n---SEP---\n%s\n' "$DATA_TODAY" "$DATA_WEEKLY" "$DATA_MONTHLY" | run_uv_python -c "
import json, sys

def split_costs(data):
    claude_cost = 0.0
    codex_cost = 0.0
    codex_tokens = 0
    for day in data.get('daily', []):
        for bd in day.get('modelBreakdowns', []):
            mn = bd.get('modelName', '')
            c = float(bd.get('cost', 0))
            if 'codex' in mn or 'gpt' in mn:
                codex_cost += c
                codex_tokens += int(bd.get('inputTokens', 0)) + int(bd.get('outputTokens', 0)) + int(bd.get('cacheCreationTokens', 0)) + int(bd.get('cacheReadTokens', 0))
            elif mn != '<synthetic>':
                claude_cost += c
    return claude_cost, codex_cost, codex_tokens

def fmt_tokens(t):
    if t >= 1_000_000_000: return f'{t/1_000_000_000:.1f}B'
    elif t >= 1_000_000: return f'{t/1_000_000:.1f}M'
    elif t >= 1_000: return f'{t/1_000:.0f}K'
    return str(t)

raw = sys.stdin.read()
parts = raw.split('---SEP---')
try:
    today = json.loads(parts[0].strip()) if len(parts) > 0 and parts[0].strip() else {'daily': []}
    weekly = json.loads(parts[1].strip()) if len(parts) > 1 and parts[1].strip() else {'daily': []}
    monthly = json.loads(parts[2].strip()) if len(parts) > 2 and parts[2].strip() else {'daily': []}
except:
    print('🤖 Error')
    print('---')
    print('❌ Failed to parse data')
    print('🔄 Refresh | refresh=true')
    sys.exit(0)

tc, txc, txt = split_costs(today)
wc, wxc, wxt = split_costs(weekly)
mc, mxc, mxt = split_costs(monthly)

# Menu bar
if txc > 0:
    print(f'🤖\${tc:.2f} 🔮\${txc:.2f}')
else:
    print(f'🤖 \${tc:.2f}')

print('---')
print('🤖 Claude Code (API equivalent) | size=14')
print('---')
print(f'📅 Today: \${tc:.2f} | font=Monaco')
print(f'📅 Week:  \${wc:.2f} | font=Monaco')
print(f'📅 30d:   \${mc:.2f} | font=Monaco')
print('---')
print('📊 Claude Daily Breakdown')
for day in sorted(weekly.get('daily', []), key=lambda x: x['date'], reverse=True):
    cc = sum(float(b.get('cost', 0)) for b in day.get('modelBreakdowns', [])
             if 'codex' not in b.get('modelName', '') and 'gpt' not in b.get('modelName', '') and b.get('modelName', '') != '<synthetic>')
    ct = sum(int(b.get('inputTokens', 0)) + int(b.get('outputTokens', 0)) + int(b.get('cacheCreationTokens', 0)) + int(b.get('cacheReadTokens', 0))
             for b in day.get('modelBreakdowns', [])
             if 'codex' not in b.get('modelName', '') and 'gpt' not in b.get('modelName', '') and b.get('modelName', '') != '<synthetic>')
    print(f'--{day[\"date\"]}: \${cc:.2f} ({fmt_tokens(ct)} tokens) | font=Monaco')

# Codex section
print('---')
print('🔮 Codex GPT-5.3 (API equivalent) | size=14')
print('---')
print(f'📅 Today: \${txc:.2f} ({fmt_tokens(txt)} tokens) | font=Monaco')
print(f'📅 Week:  \${wxc:.2f} ({fmt_tokens(wxt)} tokens) | font=Monaco')
print(f'📅 30d:   \${mxc:.2f} ({fmt_tokens(mxt)} tokens) | font=Monaco')
print('---')
print('📊 Codex Daily Breakdown')
for day in sorted(weekly.get('daily', []), key=lambda x: x['date'], reverse=True):
    xc = sum(float(b.get('cost', 0)) for b in day.get('modelBreakdowns', [])
             if 'codex' in b.get('modelName', '') or 'gpt' in b.get('modelName', ''))
    xt = sum(int(b.get('inputTokens', 0)) + int(b.get('outputTokens', 0)) + int(b.get('cacheCreationTokens', 0)) + int(b.get('cacheReadTokens', 0))
             for b in day.get('modelBreakdowns', [])
             if 'codex' in b.get('modelName', '') or 'gpt' in b.get('modelName', ''))
    if xt > 0:
        print(f'--{day[\"date\"]}: \${xc:.2f} ({fmt_tokens(xt)} tokens) | font=Monaco')

import datetime
print('---')
print(f'⏰ Updated: {datetime.datetime.now().strftime(\"%H:%M\")} | color=gray')
" 2>/dev/null
echo "📊 Weekly Report | bash='$0' param1=weekly terminal=true"
echo "📊 Monthly Report | bash='$0' param1=monthly terminal=true"
echo "📊 Session Report | bash='$0' param1=session terminal=true"
echo "🔄 Refresh | refresh=true"
