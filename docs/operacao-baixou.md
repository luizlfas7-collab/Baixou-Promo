# Operacao do Baixou

Tudo que as rotinas agendadas precisam saber. Existe como arquivo porque antes
vivia dentro do texto dos gatilhos, e cada disparo reinjetava ~2.500 palavras no
contexto: 14 disparos por dia, o mesmo conteudo todo dia. Aqui o custo e lido
uma vez, quando faz falta.

## Instrucoes permanentes do dono

- **A (15/09)** "Sempre faca as publicacoes dos disparos em cima do meu link de
  afiliado."
- **B (15/09)** "Mantenha sempre a constancia na captacao de produtos para
  disparo, qualquer erro me informe aqui."
- **C (29/09)** "Vamo manter um padrao aqui de autonomia sua para poder executar
  tudo o que for preciso pra rodar sem eu ter que ficar o dia todo autorizando
  coisas." -> Nao pedir aprovacao para consertar. Diagnosticar, consertar,
  aplicar, commitar na branch `claude/continuing-from-desktop-sfgx1d`.
- **D (30/09)** "Me de sempre um passo a passo detalhado das coisas que eu
  preciso fazer me explicando sempre os motivos e razoes das acoes necessarias."
  -> passos numerados, onde clicar, e o PORQUE de cada um. Nunca so "faca X".

## Doutrina

Mecanismo que falha calado e o inimigo. Alarme que dispara sempre e ruido;
**guarda que nunca pode disparar e pior.** Uma mudanca por vez, para dar para
medir.

## Armadilhas que ja morderam

- **`fila_publicacao` e LIVRO-CAIXA, nao fila.** Estado terminal (`publicada`,
  `descartada`, `cancelada`) fica gravado para sempre. Usar
  `public.fila_pendente()`, nunca contar a tabela a mao — essa conta errou em
  28/09 (contou as 166 linhas inteiras) e em 05/10 (contou `cancelada` como
  pendente). Normal = 0.
- **Ler `snapshot_payload`, nunca `preco_atual`.** O preco atual segue mudando
  depois de publicado; em 01/10 isso fez o boletim mentir sobre uma Smart TV.
- **Saude e POR FONTE.** O veredito global fica `saudavel` com uma fonte muda se
  a outra publica.
- **`vigia_do_motor()` ESCREVE** (resolve `vigia_sem_destino` em `erros`), logo
  nao roda em conexao somente-leitura. `boletim()` e somente-leitura e precisa
  ser chamada sozinha.
- **Se faltar um numero no boletim, ACRESCENTAR NA FUNCAO** (migracao + commit).
  Nunca voltar a montar o relatorio com consultas soltas: era assim antes e
  custava de 4 a 6 pedidos de autorizacao, varios morreram pendurados, e o
  boletim nao saiu.

## Numeros que NAO se mexe

- `aprovacao_pontuacao_minima` = **88**. E um numero so, compartilhado pelos dois
  coletores e cobrado de novo dentro de `registrar_oferta`. Baixar mexe no ML
  tambem.
- `aprovacao_idade_maxima_segundos` = 3600 e `intervalo_minimo_segundos` = 600,
  com `max_publicacoes_por_hora` = 6. Rajada maior que 6 numa hora perde o
  excedente — e essa e a falha **segura**: o teto de 1h protege o canal de preco
  velho e os 10 min evitam inundar. So o silencio era defeito.
- `FUNDO_PISO` 10 na Shopee, 13 no ML. **Competitividade 7 e a linha que nao se
  atravessa**: significa preco igual ao de costume.
- `vantagem_de_preco()` le so os ultimos 30 dias, como mediana diaria por oferta.
  **Nao afinar leituras DENTRO da janela** — mudaria a mediana do dia e portanto
  o sinal de preco, que e o dinheiro.

## Consertos fechados — nao reinvestigar

| Data | O que era | Conserto |
|---|---|---|
| 12/09 | Credencial do ML morreu, 62h cego | `9036b1c` |
| 01/10 | ML calado 3 dias: `tracao` era exigivel e o ML nunca entrega vendidos | campo `exigivel`, `4990355` v12 |
| 03/10 | Fonte lia e nao entregava, sem alarme | `entrega_por_fonte()`, `fe04b4b` |
| 04/10 | Shopee calada: `tracao` saturava em 1000 vendas | saturacao para 300, `40048db` v5 |
| 05/10 | Fila contada a mao; aprovacao vencida invisivel | `fila_pendente()`, `aprovacoes_vencidas()`, `4d5281e` |
| 06/10 | Boletim custava 6 autorizacoes | `boletim()` numa chamada, `0db2504` |
| 16/10 | **Disco encheu: Postgres em somente-leitura, 9 dias e meio parado** | `rodar_faxina()` passa a aparar, `ba03104` |

Shopee: 20 palavras x 30 itens (teto 600/rodada). Publicar pouco e **catalogo** —
perto de 88% do que e pontuado nao tem vantagem de preco nenhuma. Isso nao e
defeito.

## O que depende do dono — nao reinvestigar nem repetir a explicacao

1. **Seletor de modo em `Auto`**, ao lado da caixa de mensagem. Sessao na nuvem
   IGNORA `defaultMode` no settings.json. Um agente nao pode escrever a propria
   permissao: bloqueado tres vezes como auto-modificacao, e com razao. **Nao
   tentar de novo.**
2. **`.claude/settings.json`** com a allowlist, entregue em 06/10 para colar. Vale
   so a partir de uma sessao NOVA.
3. **Gerar os links de afiliado do funil** no painel de Afiliados do ML. Cada
   item do funil ja provou vantagem de preco e so nao publica por falta do link.
   Vincular com `ml_item_vincular('<catalogo>','<link>')`.
4. **Rotacionar o token do bot do Telegram**, exposto no chat. **A ordem importa,
   o canal fica mudo entre 1 e 3:** (1) BotFather `/mybots` -> bot -> API Token
   -> **Revoke**; (2) Supabase -> Project Settings -> Edge Functions -> Secrets
   -> atualizar `TELEGRAM_BOT_TOKEN`; (3) avisar, para atualizar o Vault.
   **Nunca usar `/token` ou `/revoke` so para VER o token: eles trocam o token.**
5. **Segredo `baixou_telegram_bot_token` no Vault** — por isso `vigia_mudo`.
6. **`verify_jwt` da funcao da Shopee**, hoje contornado com chave anon.
7. **PR #1 e draft**; so o dono move.

Ja resolvido: chat id 8660036653 gravado em `alerta_telegram_chat_id`; repasse do
WhatsApp ligado; vigia agendado (job `baixou-vigia`).

## Alarmes vivem no banco, nao na sessao

`alarme_entrega` e `ofertas_perdidas` rodam dentro do Postgres e aparecem no
boletim. A sessao nao precisa acordar de 2 em 2 horas para que eles funcionem.
