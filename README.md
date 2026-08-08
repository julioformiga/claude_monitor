# claude_monitor.sh

<img width="1269" height="535" alt="claude_monitor" src="https://github.com/user-attachments/assets/66d7968b-746f-4a3d-a297-efe7a4adeb43" />

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
redesenhadas a cada segundo e reconsultando a API a cada 60s. As
"labels" das barras mostram a contagem regressiva até o reset de cada
janela em vez de texto fixo.

```
$ ./claude_monitor.sh
```

Atalhos:
- `q` ou `Ctrl+C` — sai (restaura o terminal)
- `espaço` — força uma nova consulta à API imediatamente

## Comportamento conhecido: 401/429 na janela de 5h "fria"

Quando a janela de 5h ainda não foi iniciada (nenhuma mensagem enviada no
ciclo atual), o endpoint às vezes responde com HTTP 401 ou 429 em vez de
um 200 limpo com `utilization: 0`. O script tenta de novo (1s, depois
2s) antes de assumir que a janela está em 0% — não é tratado como erro
fatal. O valor semanal mostrado, nesse caso, é o último obtido com
sucesso (ou um aviso de indisponível, se ainda não houve nenhuma
consulta bem-sucedida nessa execução).

## Como funciona

1. Lê `claudeAiOauth.accessToken` de `~/.claude/.credentials.json`.
2. `GET https://api.anthropic.com/api/oauth/usage` com esse token como
   Bearer.
3. Extrai `five_hour.utilization` e `seven_day.utilization` (e os
   respectivos `resets_at`) da resposta.

Se a API retornar 401 de forma persistente mesmo com o 5h já iniciado, o
token provavelmente expirou — abra uma sessão do Claude Code para
renová-lo.
