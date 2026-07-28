#!/usr/bin/env bash
# ~/.claude/statusline.sh
# Claude Code diagnostic status line.
#
# Format:
#   N sessions:model:[!]week% dir@branch | Xk tok(in/out +Δ [!]pct%) | top:tool Xk/share%
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

input=$(cat)

CLAUDE_ADVISE_CTX_PCT="${CLAUDE_ADVISE_CTX_PCT:-80}"

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
  RED=$'\033[31m'
else
  SEP="" RST="" BOLD="" DIM="" CYAN="" GREEN="" YELLOW="" MAGENTA="" RED=""
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
  read -r week_pct
  read -r week_reset
  read -r model_id
  read -r cu_input
  read -r cu_cache_write
  read -r cu_cache_read
  read -r cu_output
} < <(printf '%s' "$input" | jq -r '
  .model.display_name // .model.id // "",
  .workspace.current_dir // .cwd // "",
  (.context_window.total_input_tokens // 0 | tostring),
  (.context_window.total_output_tokens // 0 | tostring),
  .context_window.used_percentage // "",
  .cost.total_cost_usd // "",
  .transcript_path // "",
  .session_id // "",
  (.rate_limits.seven_day.used_percentage // ""),
  (.rate_limits.seven_day.resets_at // ""),
  .model.id // "",
  (.context_window.current_usage.input_tokens // 0 | tostring),
  (.context_window.current_usage.cache_creation_input_tokens // 0 | tostring),
  (.context_window.current_usage.cache_read_input_tokens // 0 | tostring),
  (.context_window.current_usage.output_tokens // 0 | tostring)
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

# --- per-turn cache-aware cost (last API call only, from context_window.current_usage) ---
# `.cost.total_cost_usd` is session-cumulative and computed harness-side with the real
# rates, but doesn't expose the cache split for THIS turn. current_usage does — but only
# as a FLAT cache_creation_input_tokens; the CLI's statusLine JSON does NOT break it into
# ephemeral_5m/ephemeral_1h (verified empirically against a live payload — earlier attempt
# assumed a nested breakdown that doesn't exist here, which silently zeroed the write
# bucket and made the cache-read% meaningless — always ~100% since writes never counted).
# We can't tell 5m from 1h writes from this JSON alone, so we price the whole write bucket
# at the 1h rate (this harness's sessions run 1h TTL per client-harness bus_emit config —
# an approximation, not exact, if a call actually used 5m). Rates per-Mtok USD; keep in
# sync with anthropic.com/pricing. Sonnet 5 is on promo through 2026-08-31 (in $2/out $10;
# reverts to $3/$15 after).
price_for_model() { # model_id model_display -> "in out w5m w1h read" (empty = unknown)
  case "$1$2" in
    *sonnet-5*|*[Ss]onnet\ 5*)   printf '2 10 2.5 4 0.2' ;;
    *opus-5*|*[Oo]pus\ 5*)       printf '5 25 6.25 10 0.5' ;;
    *haiku-4-5*|*[Hh]aiku\ 4.5*) printf '1 5 1.25 2 0.1' ;;
    *) printf '' ;;
  esac
}

turn_cost=""
read -r _p_in _p_out _p_w5 _p_w1 _p_rd <<EOF
$(price_for_model "$model_id" "$model_short")
EOF
if [ -n "${_p_in:-}" ]; then
  # main session's statusLine current_usage doesn't split write into 5m/1h (see
  # note below where cu_cache_write is read) — whole write bucket priced at 1h.
  turn_cost=$(awk -v a="${cu_input:-0}" -v b="${cu_output:-0}" -v c="${cu_cache_write:-0}" \
    -v e="${cu_cache_read:-0}" \
    -v pi="$_p_in" -v po="$_p_out" -v pw="$_p_w1" -v pr="$_p_rd" \
    'BEGIN{ n=a+b+c+e; if (n<=0) exit; cost=(a*pi+b*po+c*pw+e*pr)/1000000; printf "%.4f", cost }')
fi

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

# mcp__server__tool → server:tool, everything else unchanged. Plain index()/
# substr() rather than 3-arg match(s, re, arr) — that's a gawk extension, not
# POSIX, and breaks silently (falls through to raw tool names) under mawk,
# which is what ships as /usr/bin/awk on Debian/Ubuntu (and this box).
abbrev_tool() {
  printf '%s' "$1" | awk '{
    s = $0
    if (index(s, "mcp__") == 1) {
      rest = substr(s, 6)
      p = index(rest, "__")
      if (p > 0) { printf "%s:%s", substr(rest, 1, p-1), substr(rest, p+2); next }
    }
    print s
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

# --- sub-agent spend: real $ cost, grouped by ACTUAL model (single-letter label) ---
# subagent_type (e.g. "tier-verify") only tells you which agent DEFINITION was
# requested, not what model it really ran on — defaults/pins can differ from
# what you'd guess by name (confirmed on this session's own two agents: both
# spawned as claude-code-guide, which has no model pin and was expected to
# inherit opus per a routing-hook nudge, but both actually ran on haiku). The
# only source of truth is the sub-agent's OWN transcript, which the harness
# keeps at <session-dir>/subagents/agent-<id>.jsonl — and unlike the main
# session's statusLine JSON, ITS usage objects DO carry the real
# cache_creation.ephemeral_5m/1h split, so cost here can be exact, not the
# main segment's "assume 1h" approximation.
#
# current_usage above only covers THIS session's own API calls; a spawned
# Agent burns tokens in its own separate conversation, which only surfaces
# back here as a completion-notification/result blob — has to be scraped from
# transcript text, not context_window.
#
# Correctness note: the naive approach (grep the whole transcript for every
# "subagent_tokens" occurrence and sum) overcounts badly — a background agent's
# task-notification can re-fire multiple times for the same completed run (harness
# re-notifies while idle/unconsumed), so the same number appears repeatedly. Verified
# on a real transcript: naive sum read 600k across 15 matches for what was actually
# 2 agents / 73868 tokens. Must dedupe by the agent's own id before summing.
sub_agent_count=0
sub_agent_top=""; sub_agent_top_count=0; sub_agent_top_cost=""
sub_agent_top2=""; sub_agent_top2_count=0; sub_agent_top2_cost=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # Pass 1 (parsed JSON): map agent-id -> subagent_type, via the tool_use that
  # launched it (has subagent_type) joined to its launch-ack tool_result (both
  # sync and async launches always echo "agentId: <id>" in that first result).
  # subagent_type is kept only as a fallback label if the per-agent transcript
  # (and therefore the real model/cost) turns out to be unreadable/gone.
  _sa_typemap=$(_run_jq -sc '
    ([.[] | .message.content? | select(type=="array") | .[]]) as $all
    | ($all | map(select(.type=="tool_use" and .name=="Agent") | {key:.id, value:(.input.subagent_type // "agent")}) | from_entries) as $tbt
    | ($all | map(select(.type=="tool_result" and ($tbt[.tool_use_id // ""] != null))
        | {tool_use_id, text: (.content | tostring)})) as $launches
    | ($launches | map(
        (.text | capture("agentId: (?<id>[a-f0-9]+)").id // null) as $aid
        | select($aid != null)
        | {key: $aid, value: $tbt[.tool_use_id]}
      ) | from_entries) // {}
  ' "$transcript" 2>/dev/null)
  [ -z "$_sa_typemap" ] && _sa_typemap='{}'

  # Pass 2 (raw text): every distinct agent-id that completed, deduped (same
  # dedup reasoning as above — only need the id here now, cost comes from the
  # agent's own transcript in pass 3, not from the notification text's token
  # count, which was already just a blended total anyway).
  _sa_ids=$(_run_jq -Rsr '
    [ scan("<task-id>([a-f0-9]+)</task-id>"), scan("agentId: ([a-f0-9]+) \\(") ]
    | map(.[0]) | unique | .[]
  ' "$transcript" 2>/dev/null)

  # claude-haiku-4-5-20251001 -> H (family initial only, no version — the
  # session already shows its own model+version up front; this segment is
  # meant to answer "roughly what tier, and how much", not restate a version).
  _abbrev_model_id() { printf '%s' "$1" | awk -F'-' '{print toupper(substr($2,1,1))}'; }
  _abbrev_type()      { printf '%s' "$1" | awk -F'-' '{print toupper(substr($1,1,1))}'; }

  _sa_grouped=""
  if [ -n "$_sa_ids" ]; then
    _sa_dir="$(dirname "$transcript")/${session_id}/subagents"
    while IFS= read -r _id; do
      [ -n "$_id" ] || continue
      _sub_transcript="$_sa_dir/agent-${_id}.jsonl"
      [ -f "$_sub_transcript" ] || continue

      # One pass over the agent's OWN transcript: real model + real per-tier
      # usage sums (this is a full read, not head-bounded, since cost needs
      # every turn's usage, not just the first — these files are a single
      # agent's own conversation, not the whole session, so still small).
      _sa_usage=$(_run_jq -sr '
        [.[] | select(.message.model and .message.usage)] as $turns
        | ($turns | map(.message.model) | first // "") as $model
        | ($turns | map(.message.usage)) as $u
        | "\($model) \($u | map(.input_tokens // 0) | add // 0) \($u | map(.output_tokens // 0) | add // 0) \($u | map(.cache_creation.ephemeral_5m_input_tokens // 0) | add // 0) \($u | map(.cache_creation.ephemeral_1h_input_tokens // 0) | add // 0) \($u | map(.cache_read_input_tokens // 0) | add // 0)"
      ' "$_sub_transcript" 2>/dev/null)
      [ -n "$_sa_usage" ] || continue
      read -r _u_model _u_in _u_out _u_w5 _u_w1 _u_rd <<EOF
$_sa_usage
EOF
      _label=""
      [ -n "$_u_model" ] && _label=$(_abbrev_model_id "$_u_model")
      if [ -z "$_label" ]; then
        _type=$(printf '%s' "$_sa_typemap" | _run_jq -r --arg id "$_id" '.[$id] // "agent"' 2>/dev/null)
        _label=$(_abbrev_type "$_type")
      fi

      read -r _p_in _p_out _p_w5 _p_w1 _p_rd <<EOF
$(price_for_model "$_u_model" "")
EOF
      _cost=""
      if [ -n "${_p_in:-}" ]; then
        _cost=$(awk -v a="${_u_in:-0}" -v b="${_u_out:-0}" -v c="${_u_w5:-0}" -v d="${_u_w1:-0}" -v e="${_u_rd:-0}" \
          -v pi="$_p_in" -v po="$_p_out" -v p5="$_p_w5" -v p1="$_p_w1" -v pr="$_p_rd" \
          'BEGIN{ cost=(a*pi+b*po+c*p5+d*p1+e*pr)/1000000; printf "%.6f", cost }')
      fi
      [ -n "$_cost" ] && _sa_grouped="${_sa_grouped}${_label}\t${_cost}\n"
    done <<EOF
$_sa_ids
EOF
  fi

  # Per-model breakdown, NOT a collapsed "top model's label + everyone's total"
  # (that reads as "3 agents ran opus, $X" when only 1 of the 3 did — caught
  # before shipping, not after: same top-2-by-share shape already used for the
  # tool-usage segment below, applied here for the same reason).
  if [ -n "$_sa_grouped" ]; then
    _sa_line=$(printf '%b' "$_sa_grouped" | awk -F'\t' '
      NF<2 {next}
      { sum[$1]+=$2; cnt[$1]++; n++ }
      END {
        top1=""; top1sum=-1
        for (k in sum) if (sum[k]>top1sum) { top1sum=sum[k]; top1=k }
        top2=""; top2sum=-1
        for (k in sum) if (k!=top1 && sum[k]>top2sum) { top2sum=sum[k]; top2=k }
        if (top2sum<0) top2sum=0
        printf "%d %s %d %.6f %s %d %.6f", n, top1, cnt[top1], top1sum, top2, (top2==""?0:cnt[top2]), top2sum
      }')
    # shellcheck disable=SC2086
    set -- $_sa_line
    sub_agent_count=${1:-0}
    sub_agent_top=${2:-}
    sub_agent_top_count=${3:-0}
    sub_agent_top_cost=${4:-0}
    sub_agent_top2=${5:-}
    sub_agent_top2_count=${6:-0}
    sub_agent_top2_cost=${7:-0}
  fi
fi

# --- process counts: interactive sessions machine-wide ---
# Portable: awk strips leading path so /usr/bin/claude and claude both match.
# Subagents (--input-format stream-json) are excluded from this count.
total_sessions=$(ps -eo args 2>/dev/null | awk '
  {
    b = $1; sub(/.*\//, "", b)
    if (b == "claude" && !/--input-format[[:space:]]stream-json/) sess++
  }
  END { print sess+0 }
')
: "${total_sessions:=0}"

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
    _branch=$(git -C "$_dotfiles" symbolic-ref --short HEAD 2>/dev/null) || exit 0
    _tgit -C "$_dotfiles" fetch --quiet origin "$_branch" 2>/dev/null || exit 0
    _loc=$(git -C "$_dotfiles" rev-parse HEAD 2>/dev/null)
    _rem=$(git -C "$_dotfiles" rev-parse "origin/$_branch" 2>/dev/null)
    [ -n "$_loc" ] && [ -n "$_rem" ] && [ "$_loc" != "$_rem" ] && \
      git -C "$_dotfiles" merge --ff-only --quiet "origin/$_branch" 2>/dev/null
  ) >/dev/null 2>&1 &
  disown $! 2>/dev/null || true
fi

base_turns=""
base_tok=""
base_cost=""
compacted=0
compact_saved=0
cum_input=0
cum_write=0
cum_read=0
cum_output=0
last_fp=""
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
        cum_input)     cum_input=$v ;;
        cum_write)     cum_write=$v ;;
        cum_read)      cum_read=$v ;;
        cum_output)    cum_output=$v ;;
        last_fp)       last_fp=$v ;;
      esac
    done < "$state_file"
  fi
  : "${cum_input:=0}" "${cum_write:=0}" "${cum_read:=0}" "${cum_output:=0}"

  state_dirty=0

  # Promote turn baseline on first run OR when a new user turn has appeared.
  if [ -z "$base_turns" ] || [ "$user_turns" != "$base_turns" ]; then
    # Detect compact: tok_raw dropped since last baseline
    new_compacted=0
    new_saved=0
    if [ -n "$base_tok" ] && [ "$(( tok_raw + 0 ))" -lt "$(( base_tok + 0 ))" ]; then
      new_compacted=1
      new_saved=$(( base_tok - tok_raw ))
    fi
    base_turns=$user_turns
    base_tok=$tok_raw
    base_cost=${cost_usd:-0}
    compacted=$new_compacted
    compact_saved=$new_saved
    state_dirty=1
  fi

  # Accumulate THIS API call's cache split into a session-wide running total.
  # current_usage is "last call only" — statusLine gets re-invoked many times
  # between calls (idle refreshes), so dedupe via a fingerprint of the four
  # counts: only add once per distinct call, not once per script invocation.
  _fp="${cu_input:-0}:${cu_cache_write:-0}:${cu_cache_read:-0}:${cu_output:-0}"
  if [ "$_fp" != "0:0:0:0" ] && [ "$_fp" != "$last_fp" ]; then
    cum_input=$(( cum_input + ${cu_input:-0} ))
    cum_write=$(( cum_write + ${cu_cache_write:-0} ))
    cum_read=$(( cum_read + ${cu_cache_read:-0} ))
    cum_output=$(( cum_output + ${cu_output:-0} ))
    last_fp=$_fp
    state_dirty=1
  fi

  if [ "$state_dirty" = "1" ]; then
    {
      printf 'turns=%s\n'         "$base_turns"
      printf 'tok=%s\n'           "$base_tok"
      printf 'cost=%s\n'          "$base_cost"
      printf 'compacted=%s\n'     "$compacted"
      printf 'compact_saved=%s\n' "$compact_saved"
      printf 'cum_input=%s\n'     "$cum_input"
      printf 'cum_write=%s\n'     "$cum_write"
      printf 'cum_read=%s\n'      "$cum_read"
      printf 'cum_output=%s\n'    "$cum_output"
      printf 'last_fp=%s\n'       "$last_fp"
    } > "$state_file" 2>/dev/null
  fi
fi

# --- weekly pace ("smart %"): headroom vs calendar, in units of ONE day's budget ---
# The weekly allowance spread evenly = 100/7 pp per day. By now you "should" have
# spent elapsed_fraction * 100. Positive => under pace (budget in hand), negative =>
# overdrawn. Expressed as a % of a single day's share, so +100% == a whole day spare.
smart_pct=""
smart_neg=0
if [ -n "$week_pct" ] && [ -n "$week_reset" ]; then
  read -r smart_pct smart_neg <<EOF
$(awk -v used="$week_pct" -v reset="$week_reset" -v now="$(date +%s 2>/dev/null)" 'BEGIN{
  wk = 604800
  start = (reset+0) - wk
  if (now+0 <= start || now+0 >= reset+0) exit          # stale/absent reset -> no verdict
  spent_share = ((now+0) - start) / wk * 100
  headroom    = spent_share - (used+0)
  v = headroom / (100/7) * 100                          # in units of one daily share
  printf "%.0f %d", (v < 0) ? -v : v, (headroom < 0) ? 1 : 0
}')
EOF
fi
: "${smart_neg:=0}"

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

# Compact model: first letter + version number — works for any future model family
model_abbr=$(printf '%s' "$model_short" | awk '{
  if (NF >= 2) printf "%s%s", substr($1,1,1), $2
  else          print $0
}')

# sessions:model:pace%/week% + dir + branch: "4:S4.6:30%/48% infra@main"
# pace% carries its verdict in colour alone (green = budget in hand, red = overdrawn),
# so it prints unsigned; week% is the raw weekly consumption.
_header="${dir_name}"
[ -n "$branch" ] && _header="${_header}${GREEN}@${branch}${RST}"
_model_part="${CYAN}${model_abbr}${RST}"
if [ -n "$week_pct" ]; then
  week_bang=""
  [ "$(awk -v p="$week_pct" 'BEGIN{print (p+0 >= 80) ? 1 : 0}')" = "1" ] && week_bang="!"
  _wk=$(awk -v p="$week_pct" 'BEGIN{printf "%.0f", p+0}')
  if [ -n "$smart_pct" ]; then
    pace_col="$GREEN"
    [ "$smart_neg" = "1" ] && pace_col="$RED"
    _model_part="${_model_part}${CYAN}:${RST}${pace_col}${smart_pct}%${RST}${DIM}/${RST}${CYAN}${week_bang}${_wk}%${RST}"
  else
    _model_part="${_model_part}${CYAN}:${week_bang}${_wk}%${RST}"
  fi
fi
[ -n "$model_abbr" ] && _header="${DIM}${total_sessions}:${RST}${_model_part} ${BOLD}${_header}"
parts+=("${_header}${RST}")

if [ "$tok_raw" -gt 0 ] 2>/dev/null; then
  # --- segment 1: context-window occupancy (size, not cost — cache tokens still
  # count against the window, so this must stay the gross total, unlabeled ctx% below
  # is derived from the SAME total the CLI reports as used_percentage) ---
  ctx_part=""
  if [ -n "$used_pct" ]; then
    ctx_bang=""
    [ "$ctx_urgent" = "1" ] && ctx_bang="!"
    ctx_part=$(awk -v p="$used_pct" -v b="$ctx_bang" 'BEGIN{printf "%s%.0f%%", b, p+0}')
  fi
  # sub-agent spend: real model family letter(s) — H/S/O, see sub_agent_top
  # above — with real $ cost (cache-tier-exact, from the agent's own transcript,
  # not the main segment's "assume 1h" approximation), falling back to a
  # type-initial only if a sub-transcript was unreadable. Each label carries
  # ITS OWN count×cost, not a top-model label stapled to everyone's combined
  # total (that misreads as "all N agents ran this model" when a second model
  # was mixed in). No "agents:" word-label. Sits in the slot that used to show
  # the per-turn tok delta (+Δ), which carried no real signal turn-to-turn.
  sa_part=""
  if [ "${sub_agent_count:-0}" -gt 0 ] 2>/dev/null; then
    _sa1_cost=$(awk -v c="${sub_agent_top_cost:-0}" 'BEGIN{printf "%.4f", c+0}')
    sa_part="${sub_agent_top:-?}×${sub_agent_top_count:-0} \$${_sa1_cost}"
    if [ -n "$sub_agent_top2" ] && [ "$(awk -v c="${sub_agent_top2_cost:-0}" 'BEGIN{print (c+0>0)?1:0}')" = "1" ]; then
      _sa2_cost=$(awk -v c="${sub_agent_top2_cost:-0}" 'BEGIN{printf "%.4f", c+0}')
      sa_part="${sa_part} ${sub_agent_top2}×${sub_agent_top2_count} \$${_sa2_cost}"
    fi
  fi
  tok_display="${YELLOW}↑${tok_in_str}/↓${tok_out_str}${RST}${DIM}(${sa_part:+${sa_part} }${ctx_part})${RST}"
  parts+=("$tok_display")

  # --- segment 2: cache efficiency (cost-relevant — "did the prefix survive").
  # low % means the cacheable prefix got invalidated/expired and had to be paid for
  # again (new input or cache-write) instead of a cheap cache-read. Denominator MUST
  # include cache-write tokens or this silently inflates toward 100% whenever plain
  # input_tokens is tiny, regardless of how much actually got rewritten this turn. ---
  cache_pct=$(awk -v i="${cu_input:-0}" -v wr="${cu_cache_write:-0}" -v rd="${cu_cache_read:-0}" \
    'BEGIN{ n=i+wr+rd; if (n<=0) exit; printf "%.0f", rd/n*100 }')
  sess_cache_pct=$(awk -v i="${cum_input:-0}" -v wr="${cum_write:-0}" -v rd="${cum_read:-0}" \
    'BEGIN{ n=i+wr+rd; if (n<=0) exit; printf "%.0f", rd/n*100 }')
  if [ -n "$cache_pct" ] || [ -n "$sess_cache_pct" ]; then
    cache_display="${DIM}cache:${RST}"
    if [ -n "$cache_pct" ]; then
      cache_col="$GREEN"
      [ "$(awk -v p="$cache_pct" 'BEGIN{print (p+0 < 50) ? 1 : 0}')" = "1" ] && cache_col="$RED"
      cache_display="${cache_display}${cache_col}${cache_pct}%${RST}"
    fi
    if [ -n "$sess_cache_pct" ]; then
      sess_cache_col="$GREEN"
      [ "$(awk -v p="$sess_cache_pct" 'BEGIN{print (p+0 < 50) ? 1 : 0}')" = "1" ] && sess_cache_col="$RED"
      [ -n "$cache_pct" ] && cache_display="${cache_display}${DIM}/${RST}"
      cache_display="${cache_display}${DIM}Σ${RST}${sess_cache_col}${sess_cache_pct}%${RST}"
    fi
    parts+=("$cache_display")
  fi
fi

# --- segment 3: cost (turn = cache-aware self-priced; Σ = session-cumulative, harness-authoritative) ---
if [ -n "$turn_cost" ] || { [ -n "$cost_usd" ] && [ "$cost_usd" != "0" ]; }; then
  cost_display=""
  [ -n "$turn_cost" ] && cost_display="\$${turn_cost}"
  if [ -n "$cost_usd" ] && [ "$cost_usd" != "0" ]; then
    _sess=$(awk -v c="$cost_usd" 'BEGIN{printf "%.2f", c+0}')
    if [ -n "$cost_display" ]; then
      cost_display="${cost_display} ${DIM}Σ\$${_sess}${RST}"
    else
      cost_display="Σ\$${_sess}"
    fi
  fi
  parts+=("${MAGENTA}${cost_display}${RST}")
fi

if [ "${compacted:-0}" = "1" ] && [ "${compact_saved:-0}" -gt 0 ] 2>/dev/null; then
  parts+=("${GREEN}↓compact $(format_delta "-$compact_saved") tok${RST}")
fi

if [ -n "$top_tool" ] && [ "$top_bytes" -gt 0 ] 2>/dev/null; then
  _t1=$(abbrev_tool "$top_tool")
  _t1_tok=$(format_tokens $(( top_bytes / 4 )))
  _t1_str="${_t1}×${top_calls} ${_t1_tok}"

  # show second tool if it holds >10% of tool bytes
  _t2_str=""
  if [ -n "$top2_tool" ] && [ "${top2_bytes:-0}" -gt 0 ] 2>/dev/null; then
    _t2_share=$(awk -v a="$top2_bytes" -v b="$total_tool_bytes" \
      'BEGIN{printf "%.0f", (b>0)?(a/b)*100:0}')
    if [ "$_t2_share" -ge 10 ] 2>/dev/null; then
      _t2=$(abbrev_tool "$top2_tool")
      _t2_tok=$(format_tokens $(( top2_bytes / 4 )))
      _t2_str=" ${_t2}×${top2_calls} ${_t2_tok}"
    fi
  fi

  parts+=("${MAGENTA}${_t1_str}${_t2_str}${RST}")
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
