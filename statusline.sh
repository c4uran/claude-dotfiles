#!/usr/bin/env bash
# ~/.claude/statusline.sh
# Claude Code diagnostic status line.
#
# Format:
#   N model dir@branch | files ~Xk tok | s:N ag:N | Xk tok(in/out +Δ [!]pct%) | top:tool Xk/share% | $cost(+Δ[!])
#
# The line is intentionally dense: every field carries a signal you can
# diagnose at a glance (or paste to another Claude and it can diagnose it
# for you). See README § diagnostic reading for interpretation.
#
# Portable across Linux (Synology/WSL), macOS (bash 3.2, no GNU coreutils),
# and plain Debian/Ubuntu. Hard dependencies: bash, jq, awk. Optional: git.
#
# Tunable thresholds (env vars):
#   CLAUDE_ADVISE_CTX_PCT       context %age that gets flagged with '!'   (default 80)
#   CLAUDE_ADVISE_COST_RATIO    (this turn Δcost / avg prior Δcost) to flag (default 2.5)
#   CLAUDE_ADVISE_COST_FLOOR    minimum Δcost USD for spike flag          (default 0.10)

input=$(cat)

CLAUDE_ADVISE_CTX_PCT="${CLAUDE_ADVISE_CTX_PCT:-80}"
CLAUDE_ADVISE_COST_RATIO="${CLAUDE_ADVISE_COST_RATIO:-2.5}"
CLAUDE_ADVISE_COST_FLOOR="${CLAUDE_ADVISE_COST_FLOOR:-0.10}"

# --- colors (dim palette, safe on most terminals) ---
if [ -t 1 ] || [ -n "${COLORTERM:-}" ] || [ "${TERM:-dumb}" != "dumb" ]; then
  SEP=$'\033[2;37m'
  RST=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  CYAN=$'\033[36m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  MAGENTA=$'\033[35m'
else
  SEP="" RST="" BOLD="" DIM="" CYAN="" GREEN="" YELLOW="" MAGENTA=""
fi
SEP_CHAR="${SEP}|${RST}"

# Parse all fields from input JSON in a single jq pass — avoids 8 subshell spawns.
{
  read -r model
  read -r cwd
  read -r total_session_in
  read -r total_session_out
  read -r used_pct
  read -r cost_usd
  read -r transcript
  read -r session_id
} < <(printf '%s' "$input" | jq -r '
  .model.display_name // .model.id // "",
  .workspace.current_dir // .cwd // "",
  (.context_window.total_input_tokens // 0 | tostring),
  (.context_window.total_output_tokens // 0 | tostring),
  .context_window.used_percentage // "",
  .cost.total_cost_usd // "",
  .transcript_path // "",
  .session_id // ""
' 2>/dev/null)

# --- model / dir / git branch ---
model_short="${model#Claude }"

dir_name=$(basename "${cwd:-$(pwd)}")

branch=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null || true)
fi

# --- tokens & cost ---
tok_in=${total_session_in:-0}
tok_out=${total_session_out:-0}
tok_raw=$(( tok_in + tok_out ))

# k/M formatter via awk (no bc dependency).
format_tokens() {
  awk -v n="${1:-0}" 'BEGIN{
    if (n+0 >= 1000000)   printf "%.1fM", n/1000000
    else if (n+0 >= 1000) printf "%.1fk", n/1000
    else                  printf "%d", n+0
  }'
}

format_delta() {
  awk -v n="${1:-0}" 'BEGIN{
    a = (n<0)? -n : n
    sign = (n<0)? "-" : "+"
    if (a >= 1000000)   printf "%s%.1fM", sign, a/1000000
    else if (a >= 1000) printf "%s%.1fk", sign, a/1000
    else                printf "%s%d", sign, a
  }'
}

tok_str=$(format_tokens "$tok_raw")
tok_in_str=$(format_tokens "$tok_in")
tok_out_str=$(format_tokens "$tok_out")

# --- transcript parsing: user-turn count + top tool by bytes ---
# (transcript and session_id already parsed above)

# Portable 'timeout' wrapper (macOS without coreutils has neither).
_run_jq() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 3 jq "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 3 jq "$@"
  else
    jq "$@"
  fi
}

user_turns=0
top_tool="";  top_calls=0;  top_bytes=0
top2_tool=""; top2_calls=0; top2_bytes=0
total_tool_bytes=0

# mcp__server__tool → server:tool, everything else unchanged
abbrev_tool() {
  printf '%s' "$1" | awk '{
    if (match($0, /^mcp__([^_]+)__(.+)/, a)) printf "%s:%s", a[1], a[2]
    else print $0
  }'
}
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  user_turns=$(_run_jq -c '
    select(.type=="user"
      and ((.message.content
            | if type=="array" then (.[0].type? // "text") else "text" end) != "tool_result"))
  ' "$transcript" 2>/dev/null | wc -l | tr -d '[:space:]')
  : "${user_turns:=0}"

  # Emits: total_bytes t1_name t1_calls t1_bytes t2_name t2_calls t2_bytes
  top_line=$(_run_jq -sr '
    [.[] | .message.content? | select(type=="array") | .[]] as $all
    | ($all | map(select(.type=="tool_use") | {key:.id, value:.}) | from_entries) as $byid
    | ($all | map(select(.type=="tool_use")) | group_by(.name)
        | map({key:.[0].name, value:(.|length)}) | from_entries) as $calls
    | (
        ($all | map(select(.type=="tool_use")
          | {name:.name, bytes:(.input|tostring|length)})) +
        ($all | map(select(.type=="tool_result"))
          | map(. as $r
              | ($byid[$r.tool_use_id // ""]?.name // "unknown") as $n
              | {name:$n, bytes:(.content|tostring|length)}))
      )
    | group_by(.name)
    | map({name:.[0].name, bytes:(map(.bytes)|add), calls:($calls[.[0].name] // 0)}) as $grouped
    | ($grouped | map(.bytes) | add // 0) as $total
    | ($grouped | sort_by(-.bytes) | .[0:2]) as $top2
    | "\($total) \($top2[0].name // "") \($top2[0].calls // 0) \($top2[0].bytes // 0) \($top2[1].name // "") \($top2[1].calls // 0) \($top2[1].bytes // 0)"
  ' "$transcript" 2>/dev/null)
  if [ -n "$top_line" ]; then
    # shellcheck disable=SC2086
    set -- $top_line
    total_tool_bytes=${1:-0}
    top_tool=${2:-};  top_calls=${3:-0};  top_bytes=${4:-0}
    top2_tool=${5:-}; top2_calls=${6:-0}; top2_bytes=${7:-0}
  fi
fi
: "${top_bytes:=0}"
: "${total_tool_bytes:=0}"

# --- process counts: sessions · system agents · session agents ---
# Subagents are identified by --input-format stream-json flag (never set on interactive sessions).
# Portable: awk strips leading path so /usr/bin/claude and claude both match.
_proc_counts=$(ps -eo args 2>/dev/null | awk '
  {
    b = $1; sub(/.*\//, "", b)
    if (b == "claude") {
      if (/--input-format[[:space:]]stream-json/) sys_ag++
      else sess++
    }
  }
  END { printf "%d %d", sess+0, sys_ag+0 }
')
total_sessions=$(printf '%s' "$_proc_counts" | awk '{print $1+0}')
total_sys_agents=$(printf '%s' "$_proc_counts" | awk '{print $2+0}')

# Walk up PPID chain to find the ancestor claude PID (max 5 hops).
# The statusline is spawned as: claude → bash statusline.sh, so PPID is usually claude.
_walk=$PPID; _parent_claude=""; _depth=0
while [ "$_depth" -lt 5 ]; do
  _w=$(printf '%s' "${_walk:-}" | tr -d '[:space:]')
  case "$_w" in ''|0|1) break ;; esac
  _wcomm=$(ps -o comm= -p "$_w" 2>/dev/null | tr -d '[:space:]')
  if [ "$_wcomm" = "claude" ]; then
    _parent_claude=$_w; break
  fi
  _walk=$(ps -o ppid= -p "$_w" 2>/dev/null)
  _depth=$(( _depth + 1 ))
done

sess_agents=0
if [ -n "$_parent_claude" ]; then
  sess_agents=$(ps -eo ppid,args 2>/dev/null | awk -v p="$_parent_claude" \
    '$1+0==p+0 && /--input-format[[:space:]]stream-json/{c++} END{print c+0}')
fi
: "${total_sessions:=0}"
: "${total_sys_agents:=0}"

# --- per-turn delta: baseline snapshots at the start of each user turn ---
state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$state_dir" 2>/dev/null

# --- auto-update from github (at most once per hour, fully non-blocking) ---
_upd_ts="$state_dir/last_update.ts"
_dotfiles="$HOME/.claude/dotfiles"
_do_upd=0
if [ -d "$_dotfiles/.git" ]; then
  if [ -f "$_upd_ts" ]; then
    _last_upd=$(tr -cd '0-9' < "$_upd_ts" 2>/dev/null)
    _now_ts=$(date +%s 2>/dev/null)
    _age_upd=$(( ${_now_ts:-0} - ${_last_upd:-0} ))
    [ "$_age_upd" -gt 3600 ] && _do_upd=1
  else
    _do_upd=1
  fi
fi
if [ "$_do_upd" = "1" ]; then
  date +%s > "$_upd_ts" 2>/dev/null
  (
    _tgit() {
      if command -v timeout >/dev/null 2>&1;   then timeout 15 git "$@"
      elif command -v gtimeout >/dev/null 2>&1; then gtimeout 15 git "$@"
      else git "$@"; fi
    }
    _tgit -C "$_dotfiles" fetch --quiet origin master 2>/dev/null || exit 0
    _loc=$(git -C "$_dotfiles" rev-parse HEAD 2>/dev/null)
    _rem=$(git -C "$_dotfiles" rev-parse origin/master 2>/dev/null)
    [ -n "$_loc" ] && [ -n "$_rem" ] && [ "$_loc" != "$_rem" ] && \
      git -C "$_dotfiles" merge --ff-only --quiet origin/master 2>/dev/null
  ) >/dev/null 2>&1 &
  disown $! 2>/dev/null || true
fi

base_turns=""
base_tok=""
base_cost=""
compacted=0
compact_saved=0
if [ -n "$session_id" ]; then
  state_file="$state_dir/$session_id.state"
  if [ -r "$state_file" ]; then
    while IFS='=' read -r k v; do
      case "$k" in
        turns)         base_turns=$v ;;
        tok)           base_tok=$v ;;
        cost)          base_cost=$v ;;
        compacted)     compacted=$v ;;
        compact_saved) compact_saved=$v ;;
      esac
    done < "$state_file"
  fi

  # Promote baseline on first run OR when a new user turn has appeared.
  if [ -z "$base_turns" ] || [ "$user_turns" != "$base_turns" ]; then
    # Detect compact: tok_raw dropped since last baseline
    new_compacted=0
    new_saved=0
    if [ -n "$base_tok" ] && [ "$(( tok_raw + 0 ))" -lt "$(( base_tok + 0 ))" ]; then
      new_compacted=1
      new_saved=$(( base_tok - tok_raw ))
    fi
    {
      printf 'turns=%s\n'         "$user_turns"
      printf 'tok=%s\n'           "$tok_raw"
      printf 'cost=%s\n'          "${cost_usd:-0}"
      printf 'compacted=%s\n'     "$new_compacted"
      printf 'compact_saved=%s\n' "$new_saved"
    } > "$state_file" 2>/dev/null
    base_tok=$tok_raw
    base_cost=${cost_usd:-0}
    compacted=$new_compacted
    compact_saved=$new_saved
  fi
fi

_base_tok=$(( ${base_tok:-$tok_raw} + 0 ))
delta_tok=$(( tok_raw - _base_tok ))
[ "$delta_tok" -lt 0 ] && delta_tok=0
# delta_top removed: misleads when top tool changes between turns

# Cost delta & outlier detection (float math → awk).
# delta_cost = current - base_cost (0 if missing)
# avg_prior_cost_per_turn = base_cost / max(base_turns - 1, 1)
# spike = (base_turns > 1) && (delta_cost > FLOOR) && (delta_cost > RATIO * avg)
read -r delta_cost cost_spike <<EOF
$(awk -v c="${cost_usd:-0}" -v b="${base_cost:-0}" \
       -v bt="${base_turns:-0}" -v r="$CLAUDE_ADVISE_COST_RATIO" \
       -v f="$CLAUDE_ADVISE_COST_FLOOR" 'BEGIN{
  d = (c+0) - (b+0); if (d<0) d=0
  spike = 0
  if ((bt+0) > 1) {
    prior_turns = (bt+0) - 1
    avg = (b+0) / prior_turns
    if (d > (f+0) && d > (r+0) * avg) spike = 1
  }
  printf "%.6f %d", d, spike
}')
EOF
: "${delta_cost:=0}"
: "${cost_spike:=0}"

# Context urgency flag
ctx_urgent=0
if [ -n "$used_pct" ]; then
  ctx_urgent=$(awk -v p="$used_pct" -v t="$CLAUDE_ADVISE_CTX_PCT" 'BEGIN{print (p+0 >= t+0) ? 1 : 0}')
fi

# Top-tool share of total tool bytes
top_share=0
if [ "${total_tool_bytes:-0}" -gt 0 ] 2>/dev/null; then
  top_share=$(awk -v a="$top_bytes" -v b="$total_tool_bytes" 'BEGIN{printf "%.0f", (a/b)*100}')
fi

# --- static context file token estimate ---
# Approximation: bytes / 4 across CLAUDE.md, all memory/*.md, and skills/*.md.
# Uses cwd from JSON to locate the project CLAUDE.md.
_ctx_bytes=0
_ctx_claude_md="${cwd}/CLAUDE.md"
# memory dir derived from cwd: /foo/bar/baz → project key -foo-bar-baz
_ctx_memory_dir=""
if [ -n "$cwd" ]; then
  _proj_key=$(printf '%s' "$cwd" | tr '/' '-')
  _ctx_memory_dir="$HOME/.claude/projects/${_proj_key}/memory"
fi
if [ -f "$_ctx_claude_md" ]; then
  _sz=$(wc -c < "$_ctx_claude_md" 2>/dev/null | tr -d '[:space:]')
  _ctx_bytes=$(( _ctx_bytes + ${_sz:-0} ))
fi
# all memory files are loaded into context, not just MEMORY.md
if [ -n "$_ctx_memory_dir" ] && [ -d "$_ctx_memory_dir" ]; then
  _mem_total=$(cat "$_ctx_memory_dir"/*.md 2>/dev/null | wc -c | tr -d '[:space:]')
  _ctx_bytes=$(( _ctx_bytes + ${_mem_total:-0} ))
fi
# skills: only names+descriptions are auto-injected, not full files (~150 bytes each)
_skill_count=$(ls "$HOME/.claude/skills/"*.md 2>/dev/null | wc -l | tr -d '[:space:]')
_ctx_bytes=$(( _ctx_bytes + ${_skill_count:-0} * 150 ))
# token estimate from measurable files only — no guessing system prompt / tool schemas
_ctx_tok=$(( _ctx_bytes / 4 ))
_ctx_tok_str=""
if [ "$_ctx_tok" -gt 0 ] 2>/dev/null; then
  _ctx_tok_str=$(awk -v n="$_ctx_tok" 'BEGIN{
    if (n >= 1000000)   printf "f~%.1fM", n/1000000
    else if (n >= 1000) printf "f~%.1fk", n/1000
    else                printf "f~%d", n
  }')
fi

# --- assemble line ---
parts=()

# Compact model: "Sonnet 4.6" → "S4.6", "Opus 4.7" → "O4.7", "Haiku 4.5" → "H4.5"
model_abbr=$(printf '%s' "$model_short" | awk '{
  if      ($1=="Sonnet") printf "S%s", $2
  else if ($1=="Opus")   printf "O%s", $2
  else if ($1=="Haiku")  printf "H%s", $2
  else                   print $0
}')

# model + dir + branch as one compact field: "S4.6 infra@main"
_header="${dir_name}"
[ -n "$branch" ] && _header="${_header}${GREEN}@${branch}${RST}"
[ -n "$model_abbr" ] && _header="${CYAN}${model_abbr}${RST} ${BOLD}${_header}"
parts+=("${_header}${RST}")

[ -n "$_ctx_tok_str" ] && parts+=("${DIM}${_ctx_tok_str}${RST}")

# s:N = interactive sessions machine-wide; ag:N = subagents this session / sys total
_other_agents=$(( total_sys_agents - sess_agents ))
[ "$_other_agents" -lt 0 ] && _other_agents=0
_ag_str="ag:${sess_agents}"
[ "$_other_agents" -gt 0 ] && _ag_str="${_ag_str}(+${_other_agents} other)"
parts+=("${DIM}s:${total_sessions} ${_ag_str}${RST}")

if [ "$tok_raw" -gt 0 ] 2>/dev/null; then
  # always show delta so +0 is explicit (vs missing = ambiguous)
  extra=" $(format_delta "$delta_tok")"
  pct_part=""
  if [ -n "$used_pct" ]; then
    ctx_bang=""
    [ "$ctx_urgent" = "1" ] && ctx_bang="!"
    pct_part=$(awk -v p="$used_pct" -v b="$ctx_bang" 'BEGIN{printf " %s%.0f%%", b, p+0}')
  fi
  # show in/out split so cost asymmetry (output 5x pricier) is visible
  tok_display="${YELLOW}${tok_str} tok${RST}${DIM}(↑${tok_in_str}/↓${tok_out_str}${extra}${pct_part})${RST}"
  parts+=("$tok_display")
fi

if [ "${compacted:-0}" = "1" ] && [ "${compact_saved:-0}" -gt 0 ] 2>/dev/null; then
  parts+=("${GREEN}↓compact $(format_delta "-$compact_saved") tok${RST}")
fi

if [ -n "$top_tool" ] && [ "$top_bytes" -gt 0 ] 2>/dev/null; then
  _t1=$(abbrev_tool "$top_tool")
  _t1_share=$(awk -v a="$top_bytes" -v b="$total_tool_bytes" \
    'BEGIN{printf "%.0f", (b>0)?(a/b)*100:0}')
  _t1_str="${_t1}×${top_calls}/${_t1_share}%"

  # show second tool if it holds >10% of tool bytes
  _t2_str=""
  if [ -n "$top2_tool" ] && [ "${top2_bytes:-0}" -gt 0 ] 2>/dev/null; then
    _t2_share=$(awk -v a="$top2_bytes" -v b="$total_tool_bytes" \
      'BEGIN{printf "%.0f", (b>0)?(a/b)*100:0}')
    if [ "$_t2_share" -ge 10 ] 2>/dev/null; then
      _t2=$(abbrev_tool "$top2_tool")
      _t2_str=" ${_t2}×${top2_calls}/${_t2_share}%"
    fi
  fi

  parts+=("${MAGENTA}${_t1_str}${_t2_str}${RST}")
fi

if [ -n "$cost_usd" ] && [ "$cost_usd" != "0" ] && [ "$cost_usd" != "0.0" ]; then
  cost_fmt=$(awk -v c="$cost_usd" 'BEGIN{printf "$%.4f", c+0}')
  cost_extra=""
  if [ "$(awk -v d="$delta_cost" 'BEGIN{print (d+0 > 0.0001) ? 1 : 0}')" = "1" ]; then
    bang=""
    [ "$cost_spike" = "1" ] && bang="!"
    cost_extra=$(awk -v d="$delta_cost" -v b="$bang" 'BEGIN{printf "(%s+$%.4f)", b, d}')
    cost_extra=" ${DIM}${cost_extra}${RST}"
  fi
  parts+=("${MAGENTA}${cost_fmt}${RST}${cost_extra}")
fi

result=""
for part in "${parts[@]}"; do
  [ -z "$part" ] && continue
  if [ -z "$result" ]; then
    result="$part"
  else
    result="${result} ${SEP_CHAR} ${part}"
  fi
done

# turn counter as a tight prefix — no separator, just "7 " before everything
if [ "${user_turns:-0}" -gt 0 ] 2>/dev/null; then
  result="${DIM}${user_turns}${RST} ${result}"
fi

printf '%s\n' "$result"
