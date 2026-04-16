#!/usr/bin/env bash
# ~/.claude/statusline.sh
# Claude Code diagnostic status line.
#
# Format:
#   model | dir | branch | t:N | Xk tok(+Δ [!]pct%) | ⬆tool Xk/share% | $cost(+Δ[!])
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

jq_field() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

# --- model / dir / git branch ---
model=$(jq_field '.model.display_name // .model.id // empty')
model_short="${model#Claude }"

cwd=$(jq_field '.workspace.current_dir // .cwd // empty')
dir_name=$(basename "${cwd:-$(pwd)}")

branch=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null || true)
fi

# --- tokens & cost ---
total_session_in=$(jq_field '.context_window.total_input_tokens // 0')
total_session_out=$(jq_field '.context_window.total_output_tokens // 0')
tok_raw=$(( ${total_session_in:-0} + ${total_session_out:-0} ))

used_pct=$(jq_field '.context_window.used_percentage // empty')
cost_usd=$(jq_field '.cost.total_cost_usd // empty')

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

# --- transcript parsing: user-turn count + top tool by bytes ---
transcript=$(jq_field '.transcript_path // empty')

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
top_tool=""
top_bytes=0
total_tool_bytes=0
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  user_turns=$(_run_jq -c '
    select(.type=="user"
      and ((.message.content
            | if type=="array" then (.[0].type? // "text") else "text" end) != "tool_result"))
  ' "$transcript" 2>/dev/null | wc -l | tr -d '[:space:]')
  : "${user_turns:=0}"

  # Emits three space-separated values: total_bytes top_name top_bytes
  top_line=$(_run_jq -sr '
    [.[] | .message.content? | select(type=="array") | .[]] as $all
    | ($all | map(select(.type=="tool_use") | {key:.id, value:.}) | from_entries) as $byid
    | (
        ($all | map(select(.type=="tool_use")
          | {name:.name, bytes:(.input|tostring|length)})) +
        ($all | map(select(.type=="tool_result"))
          | map(. as $r
              | ($byid[$r.tool_use_id // ""]?.name // "unknown") as $n
              | {name:$n, bytes:(.content|tostring|length)}))
      )
    | group_by(.name)
    | map({name:.[0].name, bytes:(map(.bytes)|add)}) as $grouped
    | ($grouped | map(.bytes) | add // 0) as $total
    | ($grouped | sort_by(-.bytes) | .[0] // {name:"",bytes:0}) as $top
    | "\($total) \($top.name) \($top.bytes)"
  ' "$transcript" 2>/dev/null)
  if [ -n "$top_line" ]; then
    # shellcheck disable=SC2086
    set -- $top_line
    total_tool_bytes=${1:-0}
    top_tool=${2:-}
    top_bytes=${3:-0}
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
session_id=$(jq_field '.session_id // empty')
state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$state_dir" 2>/dev/null

base_turns=""
base_tok=""
base_top_bytes=""
base_cost=""
if [ -n "$session_id" ]; then
  state_file="$state_dir/$session_id.state"
  if [ -r "$state_file" ]; then
    while IFS='=' read -r k v; do
      case "$k" in
        turns)     base_turns=$v ;;
        tok)       base_tok=$v ;;
        top_bytes) base_top_bytes=$v ;;
        cost)      base_cost=$v ;;
      esac
    done < "$state_file"
  fi

  # Promote baseline on first run OR when a new user turn has appeared.
  if [ -z "$base_turns" ] || [ "$user_turns" != "$base_turns" ]; then
    {
      printf 'turns=%s\n' "$user_turns"
      printf 'tok=%s\n'   "$tok_raw"
      printf 'top_bytes=%s\n' "$top_bytes"
      printf 'cost=%s\n'  "${cost_usd:-0}"
    } > "$state_file" 2>/dev/null
    base_tok=$tok_raw
    base_top_bytes=$top_bytes
    base_cost=${cost_usd:-0}
  fi
fi

delta_tok=$(( tok_raw - ${base_tok:-$tok_raw} ))
[ "$delta_tok" -lt 0 ] 2>/dev/null && delta_tok=0
delta_top_bytes=$(( top_bytes - ${base_top_bytes:-$top_bytes} ))
[ "$delta_top_bytes" -lt 0 ] 2>/dev/null && delta_top_bytes=0
delta_top=$(( delta_top_bytes / 4 ))

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

# --- assemble line ---
parts=()

[ -n "$model_short" ] && parts+=("${CYAN}${model_short}${RST}")
parts+=("${BOLD}${dir_name}${RST}")
[ -n "$branch" ] && parts+=("${GREEN}${branch}${RST}")

# Sessions (s:N) and agents system/session (ag:N/N) — always shown
parts+=("${DIM}s:${total_sessions} ag:${total_sys_agents}/${sess_agents}${RST}")

# Turn counter (only meaningful once we have at least one turn)
if [ "${user_turns:-0}" -gt 0 ] 2>/dev/null; then
  parts+=("${DIM}t:${user_turns}${RST}")
fi

if [ "$tok_raw" -gt 0 ] 2>/dev/null; then
  extra=""
  [ "$delta_tok" -gt 0 ] 2>/dev/null && extra=" $(format_delta "$delta_tok")"
  pct_part=""
  if [ -n "$used_pct" ]; then
    ctx_bang=""
    [ "$ctx_urgent" = "1" ] && ctx_bang="!"
    pct_part=$(awk -v p="$used_pct" -v b="$ctx_bang" 'BEGIN{printf " %s%.0f%%", b, p+0}')
  fi
  tok_display="${YELLOW}${tok_str} tok${RST}${DIM}(${extra# }${pct_part})${RST}"
  parts+=("$tok_display")
fi

if [ -n "$top_tool" ] && [ "$top_bytes" -gt 0 ] 2>/dev/null; then
  t_tok=$(format_tokens $(( top_bytes / 4 )))
  share_part=""
  [ "${top_share:-0}" -gt 0 ] 2>/dev/null && share_part="/${top_share}%"
  extra_top=""
  [ "$delta_top" -gt 0 ] 2>/dev/null && extra_top=" ${DIM}($(format_delta "$delta_top"))${RST}"
  parts+=("${MAGENTA}⬆${top_tool} ${t_tok}${share_part}${RST}${extra_top}")
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

printf '%s\n' "$result"
