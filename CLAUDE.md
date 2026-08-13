# claude_usage

Ferramenta pessoal do Julio para acompanhar os limites de uso da Claude
Code (5h e semanal) via linha de comando, sem abrir o app.

## O que tem aqui

- `claude_monitor.sh` — `bash` (usa `read -t -n`), monitor ao vivo estilo
  btop para Claude Code (limites 5h e semanal).
- `gemini_monitor.sh` — `bash` (usa `read -t -n`), monitor ao vivo estilo
  btop para Antigravity / Gemini CLI (limites 5h e semanal para modelos Gemini e terceiros/3P).

Bate no endpoint do servidor local do Antigravity (`/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`) descobrindo a porta HTTP dinamicamente dos logs em `~/.gemini/antigravity-cli/log/` ou via `ss`.

## Convenções deste projeto

- `claude_monitor.sh` e `gemini_monitor.sh` utilizam `bash` por necessidade (`read -n1` sem bloquear o timer); manter esse contrato.
- Comentários e mensagens de erro no script são em pt-BR — manter esse
  idioma ao editar ou adicionar código aqui, mesmo que a documentação
  deste arquivo esteja em pt-BR e os nomes de arquivo em inglês.
- Sem dependências além de `bash`, `jq`, `curl` e `tput` — evitar somar
  novas dependências externas sem necessidade real.
- **Nunca sintetizar valor de uso a partir de erro HTTP ou de processo.** Em falha, preservar a última leitura e sinalizar com `⚠`.
