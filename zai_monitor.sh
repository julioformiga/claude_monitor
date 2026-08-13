#!/usr/bin/env bash
# usa recursos do bash (read -t -n) para capturar teclas sem bloquear o timer
set -eu

PASS_ENTRY="Z_AI_API_KEY"
REFRESH_SECONDS=90
# teto do backoff: em falha seguida o intervalo dobra até no máximo isto
MAX_REFRESH_SECONDS=600
TMP_RESPONSE="/tmp/zai_usage_monitor.$$.json"
TMP_HEADERS="/tmp/zai_usage_monitor.$$.headers"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zai_monitor"
CACHE_FILE="$CACHE_DIR/last.json"

command -v jq >/dev/null 2>&1 || { echo "Erro: 'jq' não encontrado." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Erro: 'curl' não encontrado." >&2; exit 1; }
command -v tput >/dev/null 2>&1 || { echo "Erro: 'tput' não encontrado." >&2; exit 1; }
command -v pass >/dev/null 2>&1 || { echo "Erro: 'pass' não encontrado." >&2; exit 1; }

FALLBACK_LABEL_5H="5h"
FALLBACK_LABEL_7D="Semanal"
LABEL_WIDTH=7
# coluna única formada pelas DUAS linhas juntas (char do topo = linha do
# 5h, char de baixo = linha semanal): 14 níveis (7 por linha) que começam
# cheios e esvaziam de cima para baixo ao longo do ciclo, sem número nenhum
LEVEL_CHARS=(' ' '▂' '▃' '▄' '▅' '▆' '▇' '█')
ALERT_CHAR='⚠'
STATUS_LINE="conectando..."
FIVE_HOUR=""
WEEKLY=""
RESET_5H_EPOCH=""
RESET_7D_EPOCH=""
# epoch da última leitura boa; vazio enquanto nunca houve nenhuma
LAST_OK_EPOCH=""
# "" quando o dado na tela é da última tentativa; senão o motivo de estar
# velho: auth (401/sem key) | net (curl) | http (outro) | cache
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

# extrai os quatro valores do JSON de quota do z.ai. o endpoint devolve
# .data.limits[] com unit==3 (janela de 5h) e unit==6 (semanal).
# percentage já é o % de utilização (0-100). nextResetTime é epoch em
# milissegundos, precisa dividir por 1000 antes de passar pro date.
parse_usage_file() {
  file=$1
  parsed=$(jq -r '
    .data.limits as $limits |
    [
      ($limits[]? | select(.unit == 3) | .percentage),
      ($limits[]? | select(.unit == 3) | .nextResetTime // ""),
      ($limits[]? | select(.unit == 6) | .percentage),
      ($limits[]? | select(.unit == 6) | .nextResetTime // "")
    ] | map(tostring) | join(";")
  ' "$file" 2>/dev/null || true)

  [ -n "$parsed" ] || return 1

  IFS=';' read -r p5 r5 p7 r7 <<< "$parsed"

  # descarta null/string/ausente
  case "$p5" in
    '' | *[!0-9.]*) return 1 ;;
  esac
  case "$p7" in
    '' | *[!0-9.]*) return 1 ;;
  esac

  FIVE_HOUR=$p5
  WEEKLY=$p7
  RESET_5H_EPOCH=""
  RESET_7D_EPOCH=""
  # nextResetTime vem em milissegundos; corta os últimos 3 dígitos
  [ -n "$r5" ] && [ "$r5" != "null" ] && RESET_5H_EPOCH=$(date -d "@${r5%???}" +%s 2>/dev/null || echo "")
  [ -n "$r7" ] && [ "$r7" != "null" ] && RESET_7D_EPOCH=$(date -d "@${r7%???}" +%s 2>/dev/null || echo "")
  return 0
}

# guarda a última resposta boa para que um restart durante throttle já abra
# mostrando algo (marcado como velho) em vez de "indisponível"
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
  # dado de cache nasce velho: o alerta só some no primeiro 200 desta execução
  FAIL_KIND="cache"
  STATUS_LINE="mostrando última leitura em cache"
  return 0
}

# registra a falha SEM tocar nos valores de uso e afasta a próxima consulta.
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
  [ "$NEXT_REFRESH" -gt "$MAX_REFRESH_SECONDS" ] && NEXT_REFRESH=$MAX_REFRESH_SECONDS
  return 0
}

fetch_usage() {
  API_KEY=$(pass "$PASS_ENTRY" 2>/dev/null || true)
  if [ -z "$API_KEY" ]; then
    mark_failure auth "chave de API não encontrada em pass:$PASS_ENTRY"
    return 1
  fi

  # uma requisição por ciclo, sem rajada de retentativas
  HTTP_STATUS=$(curl -sS -o "$TMP_RESPONSE" -D "$TMP_HEADERS" -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer $API_KEY" \
    -H "Accept-Language: en-US,en" \
    "https://api.z.ai/api/monitor/usage/quota/limit" 2>/dev/null) || {
    mark_failure net "falha de conexão"
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

  case "$HTTP_STATUS" in
    401)
      mark_failure auth "401 — chave de API inválida ou expirada"
      ;;
    *)
      mark_failure http "API retornou HTTP $HTTP_STATUS"
      ;;
  esac
  return 1
}

# converte segundos restantes num texto curto tipo "4h12m", "23m", "3d4h"
format_remaining() {
  secs=$1
  [ "$secs" -lt 0 ] && secs=0
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

# repete um caractere N vezes num único bloco de texto
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

# monta a linha da barra como UMA string (retornada via variável global $BAR_LINE)
build_bar() {
  level_char=$1
  mark=$2
  mark_color=$3
  label=$4
  case "$5" in
    '' | *[!0-9.]*) pct=0 ;;
    *) pct=$(printf '%.0f' "$5") ;;
  esac
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0

  cols=$(tput cols 2>/dev/null || echo 80)
  suffix=$(printf ' %3d%%' "$pct")
  prefix_len=$((${#level_char} + 1 + ${#mark} + 1 + ${#label}))
  bar_width=$((cols - prefix_len - ${#suffix} - 3))
  [ "$bar_width" -lt 10 ] && bar_width=10

  filled=$((bar_width * pct / 100))
  empty=$((bar_width - filled))
  color=$(bar_color "$pct")
  filled_str=$(repeat_char "$filled" '█')
  empty_str=$(repeat_char "$empty" '░')

  mark_str=$mark
  [ -n "$mark_color" ] && mark_str=$(printf '\033[1;%sm%s\033[0m' "$mark_color" "$mark")

  BAR_LINE=$(printf '%s %s %s [\033[1;%sm%s\033[0m%s]%s\033[K' \
    "$level_char" "$mark_str" "$label" "$color" "$filled_str" "$empty_str" "$suffix")
}

draw_screen() {
  elapsed=$1
  remaining=$((NEXT_REFRESH - elapsed))
  [ "$remaining" -lt 0 ] && remaining=0
  total_level=$((remaining * 14 / NEXT_REFRESH))
  if [ "$total_level" -gt 14 ]; then total_level=14; fi
  bottom_level=$total_level
  if [ "$bottom_level" -gt 7 ]; then bottom_level=7; fi
  top_level=$((total_level - 7))
  if [ "$top_level" -lt 0 ]; then top_level=0; fi
  top_char="${LEVEL_CHARS[$top_level]}"
  bottom_char="${LEVEL_CHARS[$bottom_level]}"

  # ícone de alerta quando o que está na tela não veio da última tentativa.
  mark=' '
  mark_color=''
  if [ -n "$FAIL_KIND" ]; then
    mark="$ALERT_CHAR"
    case "$FAIL_KIND" in
      auth) mark_color='31' ;;
      *) mark_color='33' ;;
    esac
  fi

  if [ -n "$FIVE_HOUR" ]; then
    now=$(date +%s)
    label1="$FALLBACK_LABEL_5H"
    [ -n "$RESET_5H_EPOCH" ] && label1=$(format_remaining $((RESET_5H_EPOCH - now)))
    label1=$(printf '%-*s' "$LABEL_WIDTH" "$label1")
    build_bar "$top_char" "$mark" "$mark_color" "$label1" "$FIVE_HOUR"
    bar1="$BAR_LINE"

    if [ -n "$WEEKLY" ]; then
      label2="$FALLBACK_LABEL_7D"
      [ -n "$RESET_7D_EPOCH" ] && label2=$(format_remaining $((RESET_7D_EPOCH - now)))
      label2=$(printf '%-*s' "$LABEL_WIDTH" "$label2")
      build_bar "$bottom_char" ' ' '' "$label2" "$WEEKLY"
      bar2="$BAR_LINE"
    else
      label2=$(printf '%-*s' "$LABEL_WIDTH" "$FALLBACK_LABEL_7D")
      bar2=$(printf '%s   %s [indisponível, aguardando 1ª leitura]\033[K' "$bottom_char" "$label2")
    fi
  else
    bar1="$top_char $STATUS_LINE"$(printf '\033[K')
    bar2=$(printf '\033[K')
  fi

  # frame inteiro montado numa string só e escrito de uma vez
  frame=$(printf '%s\n%s\033[K' "$bar1" "$bar2")

  tput cup 0 0 2>/dev/null || true
  printf '%s' "$frame"
}

load_cache

tput smcup 2>/dev/null || true
tput civis 2>/dev/null || true
[ -n "$STTY_SAVED" ] && stty -echo -icanon min 0 time 0 2>/dev/null || true

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
