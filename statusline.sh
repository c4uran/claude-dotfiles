#!/usr/bin/env bash
# ~/.claude/statusline.sh
# Claude Code status line: model | dir | git branch | tokens | top-tool | cost
#
# Portable across Linux (Synology/WSL), macOS (bash 3.2, no GNU coreutils),
# and plain Debian/Ubuntu. Hard dependencies: bash, jq, awk. Optional: git.

input=$(cat)

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
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  user_turns=$(_run_jq -c '
    select(.type=="user"
      and ((.message.content
            | if type=="array" then (.[0].type? // "text") else "text" end) != "tool_result"))
  ' "$transcript" 2>/dev/null | wc -l | tr -d '[:space:]')
  : "${user_turns:=0}"

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
    | map({name:.[0].name, bytes:(map(.bytes)|add)})
    | sort_by(-.bytes)
    | .[0] // empty
    | "\(.name):\(.bytes)"
  ' "$transcript" 2>/dev/null)
  if [ -n "$top_line" ]; then
    top_tool="${top_line%%:*}"
    top_bytes="${top_line##*:}"
  fi
fi
: "${top_bytes:=0}"

# --- per-turn delta: baseline snapshots at the start of each user turn ---
session_id=$(jq_field '.session_id // empty')
state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$state_dir" 2>/dev/null

base_turns=""
base_tok=""
base_top_bytes=""
if [ -n "$session_id" ]; then
  state_file="$state_dir/$session_id.state"
  if [ -r "$state_file" ]; then
    while IFS='=' read -r k v; do
      case "$k" in
        turns)     base_turns=$v ;;
        tok)       base_tok=$v ;;
        top_bytes) base_top_bytes=$v ;;
      esac
    done < "$state_file"
  fi

  # Promote baseline on first run OR when a new user turn has appeared.
  if [ -z "$base_turns" ] || [ "$user_turns" != "$base_turns" ]; then
    {
      printf 'turns=%s\n' "$user_turns"
      printf 'tok=%s\n'   "$tok_raw"
      printf 'top_bytes=%s\n' "$top_bytes"
    } > "$state_file" 2>/dev/null
    base_tok=$tok_raw
    base_top_bytes=$top_bytes
  fi
fi

delta_tok=$(( tok_raw - ${base_tok:-$tok_raw} ))
[ "$delta_tok" -lt 0 ] 2>/dev/null && delta_tok=0
delta_top_bytes=$(( top_bytes - ${base_top_bytes:-$top_bytes} ))
[ "$delta_top_bytes" -lt 0 ] 2>/dev/null && delta_top_bytes=0
delta_top=$(( delta_top_bytes / 4 ))

# --- assemble line ---
parts=()

[ -n "$model_short" ] && parts+=("${CYAN}${model_short}${RST}")
parts+=("${BOLD}${dir_name}${RST}")
[ -n "$branch" ] && parts+=("${GREEN}${branch}${RST}")

if [ "$tok_raw" -gt 0 ] 2>/dev/null; then
  extra=""
  [ "$delta_tok" -gt 0 ] 2>/dev/null && extra=" $(format_delta "$delta_tok")"
  pct_part=""
  [ -n "$used_pct" ] && pct_part=$(awk -v p="$used_pct" 'BEGIN{printf " %.0f%%", p+0}')
  tok_display="${YELLOW}${tok_str} tok${RST}${DIM}(${extra# }${pct_part})${RST}"
  parts+=("$tok_display")
fi

if [ -n "$top_tool" ] && [ "$top_bytes" -gt 0 ] 2>/dev/null; then
  t_tok=$(format_tokens $(( top_bytes / 4 )))
  extra_top=""
  [ "$delta_top" -gt 0 ] 2>/dev/null && extra_top=" ${DIM}($(format_delta "$delta_top"))${RST}"
  parts+=("${MAGENTA}⬆${top_tool} ${t_tok}${RST}${extra_top}")
fi

if [ -n "$cost_usd" ] && [ "$cost_usd" != "0" ] && [ "$cost_usd" != "0.0" ]; then
  cost_fmt=$(awk -v c="$cost_usd" 'BEGIN{printf "$%.4f", c+0}')
  parts+=("${MAGENTA}${cost_fmt}${RST}")
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
