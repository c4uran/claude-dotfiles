#!/usr/bin/env bash
# ~/.claude/statusline.sh
# Claude Code status line: model | dir | git branch | tokens | cost

input=$(cat)

# --- colors (dim/gray palette, safe for terminals) ---
if [ -t 1 ] || [ "${COLORTERM:-}" != "" ] || [ "${TERM:-}" != "dumb" ]; then
  SEP=$'\033[2;37m'      # dim gray
  RST=$'\033[0m'         # reset
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

# --- model ---
model=$(printf '%s' "$input" | jq -r '.model.display_name // .model.id // empty' 2>/dev/null)
# shorten: "Claude 3.5 Sonnet" -> "3.5 Sonnet", strip leading "Claude "
model_short="${model#Claude }"

# --- cwd basename ---
cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
dir_name=$(basename "${cwd:-$(pwd)}")

# --- git branch (from cwd, skip optional locks) ---
branch=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
fi

# --- token usage ---
# try pre-computed used_percentage first, then compute from raw fields
total_in=$(printf '%s' "$input" | jq -r '.context_window.current_usage.input_tokens // 0' 2>/dev/null)
total_out=$(printf '%s' "$input" | jq -r '.context_window.current_usage.output_tokens // 0' 2>/dev/null)
cache_create=$(printf '%s' "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0' 2>/dev/null)
cache_read=$(printf '%s' "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0' 2>/dev/null)
total_session_in=$(printf '%s' "$input" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null)
total_session_out=$(printf '%s' "$input" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null)

# cumulative session tokens (input + output across all turns)
tok_raw=$(( total_session_in + total_session_out ))

# format with k/M suffix
format_tokens() {
  local n=$1
  if [ "$n" -ge 1000000 ] 2>/dev/null; then
    printf "%.1fM" "$(echo "scale=1; $n / 1000000" | bc 2>/dev/null || echo 0)"
  elif [ "$n" -ge 1000 ] 2>/dev/null; then
    printf "%.1fk" "$(echo "scale=1; $n / 1000" | bc 2>/dev/null || echo 0)"
  else
    printf "%d" "$n"
  fi
}

tok_str=$(format_tokens "$tok_raw")

# context window usage %
used_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)

# --- cost ---
cost_usd=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)

# --- per-turn delta (state file keyed on session_id) ---
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$state_dir" 2>/dev/null
delta_tok=0
delta_top=0
prev_top_bytes=0
if [ -n "$session_id" ]; then
  state_file="$state_dir/$session_id.state"
  if [ -f "$state_file" ]; then
    prev_tok=$(awk -F= '$1=="tok"{print $2}' "$state_file" 2>/dev/null)
    prev_top_bytes=$(awk -F= '$1=="top_bytes"{print $2}' "$state_file" 2>/dev/null)
    [ -n "$prev_tok" ] && delta_tok=$(( tok_raw - prev_tok ))
  fi
fi

# --- top tool consumer (approx, from transcript JSONL) ---
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
top_tool=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  top_tool=$(timeout 2 jq -sr '
    [.[] | .message.content? | select(type=="array") | .[]] as $all
    | ($all | map(select(.type=="tool_use")) | INDEX(.id)) as $byid
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
fi

# --- assemble line ---
parts=()

# model (cyan, shortened)
[ -n "$model_short" ] && parts+=("${CYAN}${model_short}${RST}")

# dir (bold)
parts+=("${BOLD}${dir_name}${RST}")

# git branch (green)
[ -n "$branch" ] && parts+=("${GREEN}${branch}${RST}")

# format signed delta (+1.2k / -300)
format_delta() {
  local n=$1
  if [ "$n" -gt 0 ] 2>/dev/null; then
    printf "+%s" "$(format_tokens "$n")"
  elif [ "$n" -lt 0 ] 2>/dev/null; then
    printf -- "-%s" "$(format_tokens "$(( -n ))")"
  else
    printf "+0"
  fi
}

# tokens (yellow) — only show if non-zero, with delta
if [ "$tok_raw" -gt 0 ] 2>/dev/null; then
  extra=""
  [ "$delta_tok" != "0" ] && extra=" $(format_delta "$delta_tok")"
  pct_part=""
  [ -n "$used_pct" ] && pct_part=" $(printf '%.0f' "$used_pct")%"
  tok_display="${YELLOW}${tok_str} tok${RST}${DIM}(${extra# }${pct_part})${RST}"
  parts+=("$tok_display")
fi

# top tool (magenta) — biggest byte consumer from transcript, with delta
t_bytes=0
t_name=""
if [ -n "$top_tool" ]; then
  t_name="${top_tool%%:*}"
  t_bytes="${top_tool##*:}"
  if [ -n "$t_bytes" ] && [ "$t_bytes" -gt 0 ] 2>/dev/null; then
    t_tok=$(format_tokens $(( t_bytes / 4 )))
    delta_top=$(( (t_bytes - prev_top_bytes) / 4 ))
    extra_top=""
    [ "$delta_top" != "0" ] && extra_top=" ${DIM}($(format_delta "$delta_top"))${RST}"
    parts+=("${MAGENTA}⬆${t_name} ${t_tok}${RST}${extra_top}")
  fi
fi

# persist state for next render
if [ -n "$session_id" ]; then
  {
    printf 'tok=%s\n' "$tok_raw"
    printf 'top_bytes=%s\n' "${t_bytes:-0}"
  } > "$state_file" 2>/dev/null
fi

# cost (magenta) — only if field is present and non-zero
if [ -n "$cost_usd" ] && [ "$cost_usd" != "0" ] && [ "$cost_usd" != "0.0" ]; then
  cost_fmt=$(printf '$%.4f' "$cost_usd" 2>/dev/null)
  parts+=("${MAGENTA}${cost_fmt}${RST}")
fi

# join with separator
result=""
for part in "${parts[@]}"; do
  if [ -z "$result" ]; then
    result="$part"
  else
    result="${result} ${SEP_CHAR} ${part}"
  fi
done

printf '%s\n' "$result"
