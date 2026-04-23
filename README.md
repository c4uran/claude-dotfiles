# claude-dotfiles

Scripts and configs for Claude Code. Work on macOS, Linux
(Debian/Ubuntu/Arch/Alpine), and WSL.

## statusline.sh

Diagnostic status line — densely packed so you can paste it into chat and
Claude can immediately tell what's going wrong.

**Format:**

```
<N> <model> <dir>@<branch> | f~<Xk> | s:<N> ag:<N> | <Xk> tok(↑<in>/↓<out> +<Δ> [!]<pct>%) | [↓compact -<Xk> tok] | top:<tool>×<calls>/<share>% [<tool2>×<calls>/<share>%] | $<cost> (+<Δcost>[!])
```

- `N` — your turn number, bare prefix
- `model` — abbreviated: `S4.6` = Sonnet 4.6, `O4.7` = Opus 4.7, `H4.5` = Haiku 4.5
- `f~Xk` — disk overhead: CLAUDE.md + all memory/*.md + skill list (bytes/4)
- `↑in/↓out` — input vs output token split (output costs 5× more)
- `↓compact` — appears for one turn after `/compact`, shows freed tokens
- `tool×N/share%` — top tool by bytes: call count + share of total tool traffic; second tool shown if ≥10%
- MCP tools abbreviated: `mcp__ctags__get_file` → `ctags:get_file`

Example (healthy):

```
7 S4.6 myproject@main | f~2.5k | s:1 ag:0 | 14.2k tok(↑11.0/↓3.2 +1.1k 7%) | top:Read×12/38% Bash×3/25% | $0.0312 (+$0.0180)
```

Example (after compact):

```
8 S4.6 myproject@main | f~2.5k | s:1 ag:0 | 32k tok(↑28/↓4 +0 12%) | ↓compact -85k tok | top:Read×4/42% | $0.12 (+$0.00)
```

Example (panic):

```
18 O4.7 ctf@master | f~6.1k | s:1 ag:2 | 195k tok(↑140/↓55 +85k !92%) | top:Bash×8/78% | $5.20 (!+$1.80)
```

### How to read the line

| Field | Meaning | What to watch |
|---|---|---|
| `N` | user turn number | divide `$cost` by N for average cost per turn |
| `S4.6` | active model | Opus ~5× pricier than Sonnet; use `/model sonnet` for simple tasks |
| `f~Xk` | disk file overhead (CLAUDE.md + memory + skills) | grows if memory index or CLAUDE.md bloats |
| `↑Xk/↓Yk` | input / output token split | output costs 5×; high `↓` = expensive response |
| `+Δ` | tokens added this turn (always shown, `+0` if none) | large delta = this request is heavy |
| `pct%` | context window fill | ≥80% → `!` → time to `/compact` |
| `↓compact -Xk` | tokens freed by last `/compact` | visible for one turn only |
| `tool×N/share%` | top tool by bytes: call count + share of tool traffic | `×1/40%` = one huge call → use `limit`; `×40/40%` = frequency problem → reduce calls |
| second tool | shown only when its share ≥10% | two tools both large = distributed bottleneck |
| `$X.XXXX` | total session cost | divide by N for average per request |
| `(+$Δ)` | cost delta this turn | full price of this request |
| `(!+$Δ)` | **outlier** — this turn ≥2.5× avg of prior turns | unusually expensive, check last tool calls |

**Triage order:**

1. `!pct%` → context overflowing — run `/compact`
2. `(!+$Δ)` → cost spike — open transcript, find the big tool result
3. `tool×1/N%` high share → one fat call (Read without `limit`, Bash with verbose output)
4. `tool×N/N%` high share, many calls → frequency problem, find the loop
5. Two tools both ≥25% → balanced bottleneck, no single fix
6. All fields small → healthy session

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

- `bash` ≥ 3.2 (stock macOS ships this)
- `jq` ≥ 1.5 (`from_entries` needed; avoids `INDEX` from jq 1.6 for broader compatibility)
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
2. If the counter grew — takes a new **baseline** (tokens, cost). If tokens dropped since the last baseline, records a compact event with the freed amount.
3. Otherwise — shows `current − baseline` in parens. Delta grows monotonically through the turn.

The top tool is computed from the full transcript: `tool_use.input` and
`tool_result.content` bytes summed per tool name. Call count = number of
`tool_use` entries for that name. Second tool shown only when share ≥10%.
