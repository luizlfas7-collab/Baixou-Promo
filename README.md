# Baixou

Automação que coleta ofertas de marketplaces, pontua, aprova e publica em canal
do Telegram. Projeto antes chamado **Sintonia**.

Nada a ver com o Radar Rota nem com o CRM de proteção veicular — são projetos
separados.

## Onde isso roda

| | |
|---|---|
| Supabase | projeto `baixou`, ref `xxskmxhpzbqzxoaffiul` |
| Região | `sa-east-1` (São Paulo) |
| Criado em | 16/08/2026 |
| Canal | Telegram `@aixou_promocoes` |

Este repositório foi reconstruído em 19/08/2026 a partir do banco: até então o
projeto existia **somente** no Supabase, sem cópia local nem repositório.

## Estrutura

```
supabase/
  migrations/          15 migrations, na ordem em que foram aplicadas
  functions/
    baixou-worker/     index.ts, telegram.ts, worker.ts, deno.json
    _compartilhado/    payload.ts, afiliados.ts
```

## Como o motor funciona

```
fontes → ofertas → historico_precos
                      ↓
                  aprovacoes  (amarra payload + versão exata da oferta)
                      ↓
              fila_publicacao (reserva por token, retentativa, raias)
                      ↓
                 publicacoes
```

Tabelas de apoio: `estado_destino` (reserva durável do canal), `execucoes`,
`erros`, `auditoria`, `configuracoes` (linha única, `id = 1`), `perfis`.

Todas as 11 tabelas têm RLS ligado. O navegador só lê; quem escreve é o
`service_role`, usado pelas Edge Functions.

### Garantias que estão no banco, não no código

- **Não dá para publicar conteúdo não aprovado.** A `fila_publicacao` tem
  chave estrangeira composta para `aprovacoes` em
  `(aprovacao_id, oferta_id, hash_conteudo_oferta, hash_payload)`. Enfileirar
  um payload diferente do aprovado é fisicamente impossível.
- **Um envio por destino por vez.** Advisory lock por `canal:destino` mais a
  reserva durável em `estado_destino`.
- **Resultado desconhecido vira quarentena**, não retentativa. Se o despacho
  começou e não se sabe o desfecho, o canal trava até alguém rodar
  `reconciliar_destino`.
- **Segredo do cron mora só no cofre** (`vault`), conferido por
  `cron_secreto_confere()`. Não existe cópia em variável de ambiente para sair
  de sincronia.
- Colunas `jsonb` recusam credencial e documento via
  `contem_dado_sensivel()` em CHECK constraint.
- Todo post precisa conter a linha `PUBLICIDADE • LINK DE AFILIADO`, e toda URL
  visível precisa ser de encurtador de afiliado da allowlist.

## Estado atual (19/08/2026)

Ligados: automação, coleta, aprovação automática (regra `baixou-v1`).
Aprovação humana desligada.

**Ainda travado / faltando:**

1. `trava_emergencia = true` — enquanto isso, `reservar_item_da_fila` retorna
   sem reservar nada.
2. **Nenhum job de cron agendado.** `cron.job` está vazio. A migration
   `agenda_o_worker` criou a função `disparar_worker()` e gravou
   `url_das_funcoes`, mas o `cron.schedule(...)` nunca foi executado — por isso
   o worker não roda sozinho.
3. As 5 fontes estão **todas desabilitadas** (`habilitada = false`).
4. Não existe coletor: nada chama `registrar_oferta()` ainda. As duas ofertas
   no banco entraram à mão, em teste.
5. Não existe painel — só o banco e o worker.

Última publicação real: oferta 12 → https://t.me/aixou_promocoes/4

## Segredos

Nada de segredo neste repositório. O que precisa existir:

- Cofre do banco: `baixou_worker_cron_secret`
- Secrets da Edge Function: `TELEGRAM_BOT_TOKEN` (além de `SUPABASE_URL` e
  `SUPABASE_SERVICE_ROLE_KEY`, que o Supabase injeta)

## Allowlist de afiliados

Em `supabase/functions/_compartilhado/afiliados.ts`. Hoje aceita apenas
`meli.la`, `s.shopee.com.br`, `tidd.ly` e `amzn.to`. Link fora dessa lista é
recusado antes do envio.
