# claude_usage

Ferramenta pessoal do Julio para acompanhar os limites de uso da Claude
Code (5h e semanal) via linha de comando, sem abrir o app.

## O que tem aqui

- `claude_monitor.sh` — `bash` (usa `read -t -n`), monitor ao vivo estilo
  btop, redesenha a cada segundo, reconsulta a API a cada 60s.

Bate no endpoint não-documentado da Anthropic
(`GET https://api.anthropic.com/api/oauth/usage`, Bearer token lido de
`~/.claude/.credentials.json`). Ver README.md para detalhes de uso e do
quirk de 401/429 na janela de 5h "fria".

## Convenções deste projeto

- `claude_monitor.sh` é `bash` por necessidade (`read -n1` sem bloquear o
  timer); manter esse contrato.
- Comentários e mensagens de erro no script são em pt-BR — manter esse
  idioma ao editar ou adicionar código aqui, mesmo que a documentação
  deste arquivo esteja em pt-BR e os nomes de arquivo em inglês.
- Sem dependências além de `bash`, `jq`, `curl` e `tput` — evitar somar
  novas dependências externas sem necessidade real.
