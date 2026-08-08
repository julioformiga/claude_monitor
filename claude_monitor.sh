#!/usr/bin/env bash
# usa recursos do bash (read -t -n) para capturar teclas sem bloquear o timer
set -eu

CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
REFRESH_SECONDS=60
TMP_RESPONSE="/tmp/claude_usage_monitor.$$.json"

command -v jq >/dev/null 2>&1 || { echo "Erro: 'jq' não encontrado." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Erro: 'curl' não encontrado." >&2; exit 1; }
command -v tput >/dev/null 2>&1 || { echo "Erro: 'tput' não encontrado." >&2; exit 1; }

FALLBACK_LABEL_5H="5h"
FALLBACK_LABEL_7D="Semanal"
LABEL_WIDTH=7
# coluna única formada pelas DUAS linhas juntas (char do topo = linha do
# 5h, char de baixo = linha semanal): 14 níveis (7 por linha) que começam
# cheios e esvaziam de cima para baixo ao longo dos 60s, sem número nenhum
LEVEL_CHARS=(' ' '▂' '▃' '▄' '▅' '▆' '▇' '█')
STATUS_LINE="conectando..."
FIVE_HOUR=""
WEEKLY=""
RESET_5H_EPOCH=""
RESET_7D_EPOCH=""
STTY_SAVED=""
[ -t 0 ] && STTY_SAVED=$(stty -g 2>/dev/null || true)

cleanup() {
  rm -f "$TMP_RESPONSE"
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  [ -n "$STTY_SAVED" ] && stty "$STTY_SAVED" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

fetch_usage() {
  if [ ! -f "$CREDENTIALS_FILE" ]; then
    STATUS_LINE="Erro: credenciais não encontradas em $CREDENTIALS_FILE"
    return 1
  fi
  ACCESS_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE")
  if [ -z "$ACCESS_TOKEN" ]; then
    STATUS_LINE="Erro: token de acesso ausente"
    return 1
  fi
  # a API às vezes retorna 401/429 quando a janela de 5h ainda não foi
  # iniciada (nenhuma mensagem enviada no ciclo atual), em vez de um 200
  # limpo com utilization: 0 — tenta algumas vezes antes de assumir isso
  attempt=1
  delay=1
  while [ "$attempt" -le 3 ]; do
    HTTP_STATUS=$(curl -sS -o "$TMP_RESPONSE" -w '%{http_code}' --max-time 10 \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || {
      STATUS_LINE="Erro: falha de conexão"
      return 1
    }
    [ "$HTTP_STATUS" = "200" ] && break
    case "$HTTP_STATUS" in
      401 | 429)
        [ "$attempt" -lt 3 ] && sleep "$delay"
        delay=$((delay * 2))
        ;;
      *) break ;;
    esac
    attempt=$((attempt + 1))
  done

  if [ "$HTTP_STATUS" = "200" ]; then
    FIVE_HOUR=$(jq -r '.five_hour.utilization' "$TMP_RESPONSE")
    WEEKLY=$(jq -r '.seven_day.utilization' "$TMP_RESPONSE")
    RESET_5H_EPOCH=$(date -d "$(jq -r '.five_hour.resets_at' "$TMP_RESPONSE")" +%s 2>/dev/null || echo "")
    RESET_7D_EPOCH=$(date -d "$(jq -r '.seven_day.resets_at' "$TMP_RESPONSE")" +%s 2>/dev/null || echo "")
    return 0
  fi

  if [ "$HTTP_STATUS" = "401" ] || [ "$HTTP_STATUS" = "429" ]; then
    # assume janela de 5h zerada; mantém WEEKLY/RESET_7D_EPOCH do último
    # fetch bem-sucedido (se houver) em vez de apagar o que já tínhamos
    FIVE_HOUR=0
    RESET_5H_EPOCH=""
    return 0
  fi

  STATUS_LINE="Erro: API retornou HTTP $HTTP_STATUS"
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

# repete um caractere N vezes num único bloco de texto (sem 1 printf por caractere,
# que era a principal causa do flicker: dezenas de escritas pequenas no terminal)
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
# em vez de vários printf — junto com draw_screen, isso vira uma única escrita no terminal
build_bar() {
  label=$1
  pct=$(printf '%.0f' "$2")
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0

  cols=$(tput cols 2>/dev/null || echo 80)
  suffix=$(printf ' %3d%%' "$pct")
  bar_width=$((cols - ${#label} - ${#suffix} - 3))
  [ "$bar_width" -lt 10 ] && bar_width=10

  filled=$((bar_width * pct / 100))
  empty=$((bar_width - filled))
  color=$(bar_color "$pct")
  filled_str=$(repeat_char "$filled" '█')
  empty_str=$(repeat_char "$empty" '░')

  BAR_LINE=$(printf '%s [\033[1;%sm%s\033[0m%s]%s\033[K' \
    "$label" "$color" "$filled_str" "$empty_str" "$suffix")
}

draw_screen() {
  elapsed=$1
  remaining=$((REFRESH_SECONDS - elapsed))
  [ "$remaining" -lt 0 ] && remaining=0
  total_level=$((remaining * 14 / REFRESH_SECONDS))
  [ "$total_level" -gt 14 ] && total_level=14
  bottom_level=$total_level
  [ "$bottom_level" -gt 7 ] && bottom_level=7
  top_level=$((total_level - 7))
  [ "$top_level" -lt 0 ] && top_level=0
  top_char="${LEVEL_CHARS[$top_level]}"
  bottom_char="${LEVEL_CHARS[$bottom_level]}"

  if [ -n "$FIVE_HOUR" ]; then
    now=$(date +%s)
    label1="$FALLBACK_LABEL_5H"
    [ -n "$RESET_5H_EPOCH" ] && label1=$(format_remaining $((RESET_5H_EPOCH - now)))
    label1=$(printf '%-*s' "$LABEL_WIDTH" "$label1")
    build_bar "$top_char $label1" "$FIVE_HOUR"
    bar1="$BAR_LINE"

    if [ -n "$WEEKLY" ]; then
      label2="$FALLBACK_LABEL_7D"
      [ -n "$RESET_7D_EPOCH" ] && label2=$(format_remaining $((RESET_7D_EPOCH - now)))
      label2=$(printf '%-*s' "$LABEL_WIDTH" "$label2")
      build_bar "$bottom_char $label2" "$WEEKLY"
      bar2="$BAR_LINE"
    else
      label2=$(printf '%-*s' "$LABEL_WIDTH" "$FALLBACK_LABEL_7D")
      bar2=$(printf '%s %s [indisponível, aguardando 1ª leitura]\033[K' "$bottom_char" "$label2")
    fi
  else
    bar1="$top_char $STATUS_LINE"$(printf '\033[K')
    bar2=$(printf '\033[K')
  fi

  # frame inteiro montado numa string só e escrito de uma vez (printf único no fim):
  # evita o "clarão" de limpar a tela toda e depois redesenhar aos pedaços
  frame=$(printf '%s\n%s\033[K' "$bar1" "$bar2")

  tput cup 0 0
  printf '%s' "$frame"
}

tput smcup 2>/dev/null || true
tput civis 2>/dev/null || true
[ -n "$STTY_SAVED" ] && stty -echo -icanon min 0 time 0 2>/dev/null || true

elapsed=$REFRESH_SECONDS
while :; do
  if [ "$elapsed" -ge "$REFRESH_SECONDS" ]; then
    fetch_usage || true
    elapsed=0
  fi
  draw_screen "$elapsed"

  key=""
  IFS= read -r -t 1 -n 1 key || true
  case "$key" in
    q) break ;;
    ' ') elapsed=$REFRESH_SECONDS ;;
    *) elapsed=$((elapsed + 1)) ;;
  esac
done
