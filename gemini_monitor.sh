#!/usr/bin/env bash
# usa recursos do bash (read -t -n) para capturar teclas sem bloquear o timer
set -eu

REFRESH_SECONDS=90
# teto do backoff: em falha seguida o intervalo dobra até no máximo isto
MAX_REFRESH_SECONDS=600
TMP_RESPONSE="/tmp/google_usage_monitor.$$.json"
TMP_HEADERS="/tmp/google_usage_monitor.$$.headers"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/google_monitor"
CACHE_FILE="$CACHE_DIR/last.json"

command -v jq >/dev/null 2>&1 || { echo "Erro: 'jq' não encontrado." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Erro: 'curl' não encontrado." >&2; exit 1; }
command -v tput >/dev/null 2>&1 || { echo "Erro: 'tput' não encontrado." >&2; exit 1; }

FALLBACK_LABEL_G5="G-5h"
FALLBACK_LABEL_G7="G-Sem"
FALLBACK_LABEL_P5="3P-5h"
FALLBACK_LABEL_P7="3P-Sem"
LABEL_WIDTH=7

# coluna única formada pelas QUATRO linhas juntas (14 níveis distribuídos)
LEVEL_CHARS=(' ' '▂' '▃' '▄' '▅' '▆' '▇' '█')
ALERT_CHAR='⚠'
STATUS_LINE="conectando ao Antigravity..."

GEMINI_5H=""
GEMINI_WEEKLY=""
P3_5H=""
P3_WEEKLY=""

RESET_G5_EPOCH=""
RESET_G7_EPOCH=""
RESET_P5_EPOCH=""
RESET_P7_EPOCH=""

LAST_OK_EPOCH=""
FAIL_KIND=""
CONSEC_FAILS=0
NEXT_REFRESH=$REFRESH_SECONDS
STTY_SAVED=""
if [ -t 0 ]; then
  STTY_SAVED=$(stty -g 2>/dev/null || true)
fi

cleanup() {
  rm -f "$TMP_RESPONSE" "$TMP_HEADERS"
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  if [ -n "$STTY_SAVED" ]; then
    stty "$STTY_SAVED" 2>/dev/null || true
  fi
  return 0
}
trap cleanup EXIT INT TERM

# busca a porta do servidor HTTP do Antigravity (agy)
find_agy_port() {
  # 1. Tenta encontrar nos arquivos de log mais recentes do antigravity
  for log in $(ls -t "$HOME/.gemini/antigravity-cli/log/cli-"*.log 2>/dev/null || true); do
    p=$(grep -oP 'Language server listening on random port at \K[0-9]+(?= for HTTP\b)' "$log" 2>/dev/null | tail -n 1 || true)
    if [ -n "$p" ]; then
      if curl -s -m 2 -X POST -H "Content-Type: application/json" -d '{}' "http://127.0.0.1:$p/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary" 2>/dev/null | grep -q '"groups"'; then
        printf '%s' "$p"
        return 0
      fi
    fi
  done

  # 2. Tenta encontrar nas portas em escuta do agy via ss
  if command -v ss >/dev/null 2>&1; then
    for p in $(ss -tulpn 2>/dev/null | grep '"agy"' | grep -oP '127\.0\.0\.1:\K[0-9]+' || true); do
      if curl -s -m 2 -X POST -H "Content-Type: application/json" -d '{}' "http://127.0.0.1:$p/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary" 2>/dev/null | grep -q '"groups"'; then
        printf '%s' "$p"
        return 0
      fi
    done
  fi

  return 1
}

parse_usage_file() {
  file=$1
  parsed=$(jq -r '
    .response.groups as $g |
    ($g[]? | select(.displayName == "Gemini Models")) as $gem |
    ($g[]? | select(.displayName | test("Claude|3p|GPT"; "i"))) as $tp |
    [
      ($gem.buckets[]? | select(.window == "5h") | .remainingFraction),
      ($gem.buckets[]? | select(.window == "5h") | .resetTime // ""),
      ($gem.buckets[]? | select(.window == "weekly") | .remainingFraction),
      ($gem.buckets[]? | select(.window == "weekly") | .resetTime // ""),
      ($tp.buckets[]? | select(.window == "5h") | .remainingFraction),
      ($tp.buckets[]? | select(.window == "5h") | .resetTime // ""),
      ($tp.buckets[]? | select(.window == "weekly") | .remainingFraction),
      ($tp.buckets[]? | select(.window == "weekly") | .resetTime // "")
    ] | map(tostring) | join(";")
  ' "$file" 2>/dev/null || true)

  [ -n "$parsed" ] || return 1

  IFS=';' read -r g5_rem g5_res g7_rem g7_res p5_rem p5_res p7_rem p7_res <<< "$parsed"

  case "$g5_rem" in
    '' | *[!0-9.]*) return 1 ;;
  esac

  # percentual de utilização = (1 - remainingFraction) * 100
  GEMINI_5H=$(awk -v r="$g5_rem" 'BEGIN { printf "%.1f", (1 - r) * 100 }')
  GEMINI_WEEKLY=$(awk -v r="$g7_rem" 'BEGIN { printf "%.1f", (1 - r) * 100 }')
  P3_5H=$(awk -v r="${p5_rem:-1}" 'BEGIN { printf "%.1f", (1 - r) * 100 }')
  P3_WEEKLY=$(awk -v r="${p7_rem:-1}" 'BEGIN { printf "%.1f", (1 - r) * 100 }')

  RESET_G5_EPOCH=""
  RESET_G7_EPOCH=""
  RESET_P5_EPOCH=""
  RESET_P7_EPOCH=""

  if [ -n "$g5_res" ]; then RESET_G5_EPOCH=$(date -d "$g5_res" +%s 2>/dev/null || echo ""); fi
  if [ -n "$g7_res" ]; then RESET_G7_EPOCH=$(date -d "$g7_res" +%s 2>/dev/null || echo ""); fi
  if [ -n "$p5_res" ]; then RESET_P5_EPOCH=$(date -d "$p5_res" +%s 2>/dev/null || echo ""); fi
  if [ -n "$p7_res" ]; then RESET_P7_EPOCH=$(date -d "$p7_res" +%s 2>/dev/null || echo ""); fi

  return 0
}

write_cache() {
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  tmp="$CACHE_FILE.$$"
  if jq --argjson at "$1" '. + {fetched_at: $at}' "$TMP_RESPONSE" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$CACHE_FILE" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

load_cache() {
  [ -f "$CACHE_FILE" ] || return 0
  parse_usage_file "$CACHE_FILE" || return 0
  LAST_OK_EPOCH=$(jq -r '.fetched_at | numbers // empty' "$CACHE_FILE" 2>/dev/null || true)
  FAIL_KIND="cache"
  STATUS_LINE="mostrando última leitura em cache"
  return 0
}

mark_failure() {
  FAIL_KIND=$1
  STATUS_LINE=$2
  CONSEC_FAILS=$((CONSEC_FAILS + 1))
  NEXT_REFRESH=$REFRESH_SECONDS
  i=0
  while [ "$i" -lt "$CONSEC_FAILS" ] && [ "$NEXT_REFRESH" -lt "$MAX_REFRESH_SECONDS" ]; do
    NEXT_REFRESH=$((NEXT_REFRESH * 2))
    i=$((i + 1))
  done
  if [ "$NEXT_REFRESH" -gt "$MAX_REFRESH_SECONDS" ]; then NEXT_REFRESH=$MAX_REFRESH_SECONDS; fi
  return 0
}

fetch_usage() {
  AGY_PORT=$(find_agy_port || true)
  if [ -z "$AGY_PORT" ]; then
    mark_failure auth "servidor Antigravity (agy) não encontrado"
    return 1
  fi

  HTTP_STATUS=$(curl -sS -o "$TMP_RESPONSE" -D "$TMP_HEADERS" -w '%{http_code}' --max-time 10 \
    -X POST -H "Content-Type: application/json" -d '{}' \
    "http://127.0.0.1:$AGY_PORT/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary" 2>/dev/null) || {
    mark_failure net "falha de conexão com agy na porta $AGY_PORT"
    return 1
  }

  if [ "$HTTP_STATUS" = "200" ]; then
    if parse_usage_file "$TMP_RESPONSE"; then
      LAST_OK_EPOCH=$(date +%s)
      FAIL_KIND=""
      STATUS_LINE=""
      CONSEC_FAILS=0
      NEXT_REFRESH=$REFRESH_SECONDS
      write_cache "$LAST_OK_EPOCH"
      return 0
    fi
    mark_failure http "resposta 200 sem percentuais válidos"
    return 1
  fi

  mark_failure http "servidor retornou HTTP $HTTP_STATUS"
  return 1
}

format_remaining() {
  secs=$1
  if [ "$secs" -lt 0 ]; then secs=0; fi
  d=$((secs / 86400))
  h=$(((secs % 86400) / 3600))
  m=$(((secs % 3600) / 60))
  s=$((secs % 60))
  if [ "$d" -gt 0 ]; then
    printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then
    printf '%dh%dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then
    printf '%dm' "$m"
  else
    printf '%ds' "$s"
  fi
}

bar_color() {
  pct=$1
  if [ "$pct" -ge 90 ]; then printf '31'
  elif [ "$pct" -ge 70 ]; then printf '33'
  else printf '32'; fi
}

repeat_char() {
  n=$1
  ch=$2
  out=""
  i=0
  while [ "$i" -lt "$n" ]; do
    out="$out$ch"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

build_bar() {
  level_char=$1
  mark=$2
  mark_color=$3
  label=$4
  case "$5" in
    '' | *[!0-9.]*) pct=0 ;;
    *) pct=$(printf '%.0f' "$5") ;;
  esac
  if [ "$pct" -gt 100 ]; then pct=100; fi
  if [ "$pct" -lt 0 ]; then pct=0; fi

  cols=$(tput cols 2>/dev/null || echo 80)
  suffix=$(printf ' %3d%%' "$pct")
  prefix_len=$((${#level_char} + 1 + ${#mark} + 1 + ${#label}))
  bar_width=$((cols - prefix_len - ${#suffix} - 3))
  if [ "$bar_width" -lt 10 ]; then bar_width=10; fi

  filled=$((bar_width * pct / 100))
  empty=$((bar_width - filled))
  color=$(bar_color "$pct")
  filled_str=$(repeat_char "$filled" '█')
  empty_str=$(repeat_char "$empty" '░')

  mark_str=$mark
  if [ -n "$mark_color" ]; then mark_str=$(printf '\033[1;%sm%s\033[0m' "$mark_color" "$mark"); fi

  BAR_LINE=$(printf '%s %s %s [\033[1;%sm%s\033[0m%s]%s\033[K' \
    "$level_char" "$mark_str" "$label" "$color" "$filled_str" "$empty_str" "$suffix")
}

draw_screen() {
  elapsed=$1
  remaining=$((NEXT_REFRESH - elapsed))
  if [ "$remaining" -lt 0 ]; then remaining=0; fi
  total_level=$((remaining * 28 / NEXT_REFRESH))
  if [ "$total_level" -gt 28 ]; then total_level=28; fi

  l1=$total_level
  if [ "$l1" -gt 7 ]; then l1=7; fi

  l2=$((total_level - 7))
  if [ "$l2" -lt 0 ]; then l2=0; fi
  if [ "$l2" -gt 7 ]; then l2=7; fi

  l3=$((total_level - 14))
  if [ "$l3" -lt 0 ]; then l3=0; fi
  if [ "$l3" -gt 7 ]; then l3=7; fi

  l4=$((total_level - 21))
  if [ "$l4" -lt 0 ]; then l4=0; fi

  c1="${LEVEL_CHARS[$l4]}"
  c2="${LEVEL_CHARS[$l3]}"
  c3="${LEVEL_CHARS[$l2]}"
  c4="${LEVEL_CHARS[$l1]}"

  mark=' '
  mark_color=''
  if [ -n "$FAIL_KIND" ]; then
    mark="$ALERT_CHAR"
    case "$FAIL_KIND" in
      auth) mark_color='31' ;;
      *) mark_color='33' ;;
    esac
  fi

  if [ -n "$GEMINI_5H" ]; then
    now=$(date +%s)

    label1="$FALLBACK_LABEL_G5"
    if [ -n "$RESET_G5_EPOCH" ]; then
      label1="G $(format_remaining $((RESET_G5_EPOCH - now)))"
    fi
    label1=$(printf '%-*s' "$LABEL_WIDTH" "$label1")
    build_bar "$c1" "$mark" "$mark_color" "$label1" "$GEMINI_5H"
    bar1="$BAR_LINE"

    label2="$FALLBACK_LABEL_G7"
    if [ -n "$RESET_G7_EPOCH" ]; then
      label2="G $(format_remaining $((RESET_G7_EPOCH - now)))"
    fi
    label2=$(printf '%-*s' "$LABEL_WIDTH" "$label2")
    build_bar "$c2" ' ' '' "$label2" "$GEMINI_WEEKLY"
    bar2="$BAR_LINE"

    label3="$FALLBACK_LABEL_P5"
    if [ -n "$RESET_P5_EPOCH" ]; then
      label3="3P $(format_remaining $((RESET_P5_EPOCH - now)))"
    fi
    label3=$(printf '%-*s' "$LABEL_WIDTH" "$label3")
    build_bar "$c3" ' ' '' "$label3" "$P3_5H"
    bar3="$BAR_LINE"

    label4="$FALLBACK_LABEL_P7"
    if [ -n "$RESET_P7_EPOCH" ]; then
      label4="3P $(format_remaining $((RESET_P7_EPOCH - now)))"
    fi
    label4=$(printf '%-*s' "$LABEL_WIDTH" "$label4")
    build_bar "$c4" ' ' '' "$label4" "$P3_WEEKLY"
    bar4="$BAR_LINE"
  else
    bar1="$c1 $STATUS_LINE"$(printf '\033[K')
    bar2=$(printf '\033[K')
    bar3=$(printf '\033[K')
    bar4=$(printf '\033[K')
  fi

  frame=$(printf '%s\n%s\n%s\n%s\033[K' "$bar1" "$bar2" "$bar3" "$bar4")

  tput cup 0 0 2>/dev/null || true
  printf '%s' "$frame"
}

load_cache

tput smcup 2>/dev/null || true
tput civis 2>/dev/null || true
if [ -n "$STTY_SAVED" ]; then
  stty -echo -icanon min 0 time 0 2>/dev/null || true
fi

elapsed=$NEXT_REFRESH
while :; do
  if [ "$elapsed" -ge "$NEXT_REFRESH" ]; then
    fetch_usage || true
    elapsed=0
  fi
  draw_screen "$elapsed"

  key=""
  IFS= read -r -t 1 -n 1 key || true
  case "$key" in
    q) exit 0 ;;
    ' ') elapsed=$NEXT_REFRESH ;;
    *) elapsed=$((elapsed + 1)) ;;
  esac
done

exit 0
