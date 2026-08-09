# claude_monitor.sh

<img width="1263" height="530" alt="claude_monitor" src="https://github.com/user-attachments/assets/678d6741-3d64-42b0-9418-241f07677f72" />

Script de shell para acompanhar o uso da Claude Code (limites de 5 horas
e semanal) sem precisar abrir o app.

Usa um endpoint não-documentado da Anthropic (`/api/oauth/usage`), lendo
o token de acesso direto do arquivo de credenciais do Claude Code.

## Requisitos

- `bash`
- `jq`
- `curl`
- `tput`
- Uma sessão do Claude Code já autenticada (`~/.claude/.credentials.json`
  precisa existir e ter um `accessToken` válido)

## `claude_monitor.sh`

Monitor ao vivo, estilo btop: duas barras (uma por limite) ocupando a
largura do terminal, coloridas por faixa (verde/amarelo/vermelho),
redesenhadas a cada segundo e reconsultando a API a cada 90s. As
"labels" das barras mostram a contagem regressiva até o reset de cada
janela em vez de texto fixo.

```
$ ./claude_monitor.sh
```

Atalhos:
- `q` ou `Ctrl+C` — sai (restaura o terminal)
- `espaço` — força uma nova consulta à API imediatamente

## Quando a consulta falha: o ícone `⚠`

O endpoint `/api/oauth/usage` tem um throttle apertado e responde **429**
com alguma frequência — poucas consultas seguidas já bastam para
estourá-lo. O 429 não diz nada sobre o uso real, e o 401 significa token
expirado; **nenhum dos dois é motivo para zerar a barra**.

Em qualquer falha o script mantém a última leitura conhecida na tela e
liga um ícone de alerta ao lado da contagem regressiva:

```
▆ ⚠ 1h20m [██████████░░░░░░░░░░]  45%     ← dado preservado, consulta falhou
▃   4d13m [████████░░░░░░░░░░░░]  39%
```

- `⚠` amarelo — throttle (429), falha de rede, resposta inesperada, ou
  leitura vinda do cache em disco.
- `⚠` vermelho — 401: o token expirou. Abra uma sessão do Claude Code
  para renová-lo.

O ícone some na primeira consulta bem-sucedida. Ele ocupa um slot fixo,
então as colunas não se deslocam quando aparece.

Para não realimentar o throttle, é **uma requisição por ciclo** (sem
rajada de retentativas) e, a cada falha seguida, o intervalo dobra:
90s → 180s → 360s → 600s (teto), voltando a 90s no primeiro 200. Um
`Retry-After` maior que zero é respeitado. `espaço` força uma consulta
imediata mesmo durante o backoff.

## Como funciona

1. Lê `claudeAiOauth.accessToken` de `~/.claude/.credentials.json`.
2. `GET https://api.anthropic.com/api/oauth/usage` com esse token como
   Bearer.
3. Extrai `five_hour.utilization` e `seven_day.utilization` (e os
   respectivos `resets_at`) da resposta, aceitando só valores numéricos
   — vários campos do payload vêm `null`.
4. Guarda a resposta em `~/.cache/claude_monitor/last.json` (respeita
   `XDG_CACHE_HOME`). Assim, se o monitor subir e cair no throttle logo
   de cara, já abre mostrando a última leitura com `⚠` em vez de
   "indisponível".
