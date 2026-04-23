# claude-dotfiles

Scripts and configs for Claude Code. Work on macOS, Linux
(Debian/Ubuntu/Arch/Alpine), and WSL.

## statusline.sh

Diagnostic status line — densely packed so you can paste it into chat and
Claude can immediately tell what's going wrong.

**Format:**

```
<N> <model> <dir>@<branch> | static ~<Xk> tok | s:<N> ag:<N> | <Xk> tok(<in>in/<out>out +<Δ> [!]<pct>%) | top:<tool> <Xk>/<share>% | $<cost> (+<Δcost>[!])
```

- `N` — your turn number, bare prefix, no separator
- `model` — abbreviated: `S4.6` = Sonnet 4.6, `O4.7` = Opus 4.7, `H4.5` = Haiku 4.5
- `static ~Xk tok` — estimated fixed overhead: CLAUDE.md + MEMORY.md + skill list

Example (healthy):

```
7 S4.6 myproject@main | static ~8.2k tok | s:1 ag:0 | 14.2k tok(11.0in/3.2out +1.1k 7%) | top:Read 4.2k/38% | $0.0312 (+$0.0180)
```

Example (panic):

```
18 O4.7 ctf@master | static ~6.1k tok | s:1 ag:2 | 195k tok(140in/55out +85k !92%) | top:Bash 180k/78% | $5.20 (!+$1.80)
```

### How to read the line

| Field | Meaning | What to watch |
|---|---|---|
| `N` | user turn number | divide `$cost` by N for average cost per turn |
| `S4.6` | active model | Opus ~5× pricier than Sonnet; use `/model sonnet` for simple tasks |
| `static ~Xk tok` | fixed overhead from project files | grows if CLAUDE.md / memory index bloats |
| `Xk tok` | total session input+output tokens | compare with `pct%`, not in isolation |
| `(Xin/Yout ...)` | input vs output split | output costs 5× more; high `out` = expensive response |
| `+Δ` | tokens added this turn (always shown, `+0` if none) | large delta = this request is heavy |
| `pct%` | context window fill | ≥80% → `!` → time to `/compact` |
| `top:tool Xk` | top tool by `tool_use.input + tool_result.content` bytes | who is the bottleneck |
| `/N%` | top tool's share of all tool bytes | 70%+ = clear bottleneck; 20–30% = balanced |
| `$X.XXXX` | total session cost | divide by turn number for average per request |
| `(+$Δ)` | cost delta this turn | full price of this request |
| `(!+$Δ)` | **outlier** — this turn ≥ 2.5× avg of prior turns | unusually expensive, check last tool calls |

**Triage order:**

1. `!pct%` → context overflowing, nothing else matters — run `/compact`
2. `(!+$Δ)` → cost spike this turn — open transcript, find the big tool result
3. `top:tool` share ≥70% → bottleneck in that tool (usually `Bash` with fat output, or `Read` without `limit`)
4. `$cost / N` growing non-linearly → session degrading, consider `/compact` or new window
5. All fields small → healthy session

### Thresholds

Tunable via env vars:

| env | default | effect |
|---|---|---|
| `CLAUDE_ADVISE_CTX_PCT` | `80` | context % that triggers `!` flag |
| `CLAUDE_ADVISE_COST_RATIO` | `2.5` | how many × avg a turn must cost to be flagged as spike |
| `CLAUDE_ADVISE_COST_FLOOR` | `0.10` | minimum Δcost USD for spike to fire (suppresses noise on cheap sessions) |

### Install

Clone into a permanent location and run the installer:

```bash
git clone https://github.com/c4uran/claude-dotfiles.git ~/.claude/dotfiles
bash ~/.claude/dotfiles/install.sh
```

The installer:
1. Detects OS (macOS / Debian / Arch / Alpine / WSL).
2. Checks for `bash`, `jq >= 1.5`, `awk`. Prints install command and exits 1 if missing.
3. Symlinks `~/.claude/statusline.sh → dotfiles/statusline.sh` (backs up existing file to `.bak.<ts>`).
4. Prints the `settings.json` snippet to add manually.

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

### Dependencies

Required:

- `bash` >= 3.2 (stock macOS ships this)
- `jq` >= 1.5 (`from_entries` needed; avoids `INDEX` from jq 1.6 for broader compatibility)
- `awk` (any — BSD awk / gawk / mawk)

Optional:

- `git` — for branch display

Install by platform:

| OS | Command |
|---|---|
| macOS | `brew install jq git` |
| Debian / Ubuntu / WSL | `sudo apt-get install -y jq git` |
| Arch | `sudo pacman -S --needed jq git` |
| Alpine | `sudo apk add jq git` |

### How per-turn delta works

State is stored in `$XDG_CACHE_HOME/claude-statusline/<session_id>.state`
(default: `~/.cache/claude-statusline/`).

On each render the script:

1. Counts real user turns in the transcript (filters out `tool_result` messages).
2. If the counter grew — takes a new **baseline** (current tokens, top-tool bytes, cost). This marks "start of new request".
3. Otherwise — shows `current − baseline` in parens. Delta grows monotonically through the turn until you send the next message.

This means the delta shows the full cost of **this request**, not noise between renders.

The top tool is computed from the full transcript: `tool_use.input` and
`tool_result.content` bytes are summed per tool name and the largest wins.
