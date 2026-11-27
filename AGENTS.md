# Baixou — leia antes de mexer

Dois agentes trabalham neste projeto: **Claude Code** e **Codex**. Este arquivo
é o ponto de encontro dos dois. O Codex lê `AGENTS.md`, o Claude Code lê
`CLAUDE.md`, e o `CLAUDE.md` aponta para cá — então existe **um documento só**.

> Se você está lendo isto e vai alterar alguma coisa: o risco deste projeto não
> é código ruim, é **mudança invisível**. O Supabase não tem merge. Função
> publicada e migração aplicada não têm histórico de conflito. Dois agentes
> mexendo sem registro é como a produção e o repositório param de contar a
> mesma história.

## O que é

Automação de queda de preço. Lê preço nas lojas, compara com o histórico que
ela mesma observou, e publica no canal `@aixou_promocoes` do Telegram **sempre
em cima do link de afiliado do dono**. Supabase (Postgres + Edge Functions +
pg_cron + pg_net). Sem frontend.

## Regras que não se quebram

1. **Todo disparo sai no link de afiliado do dono.** Instrução permanente dele.
   A allowlist em `_compartilhado/afiliados.ts` é a barreira; nunca afrouxar.
2. **`fila_publicacao` é livro-caixa, não fila.** Estados terminais:
   `publicada`, `descartada`, `cancelada`. Pendente normal = 0. Contar **sempre**
   por `public.fila_pendente()`, nunca na mão — essa conta já errou duas vezes.
3. **Ler `snapshot_payload`, nunca `preco_atual`.** O preço continua se movendo
   depois de publicado; em 01/10 isso fez o boletim mentir sobre uma Smart TV.
4. **`aprovacao_pontuacao_minima` = 88, um número só**, compartilhado pelas
   fontes e cobrado de novo dentro de `registrar_oferta`. Não baixar.
5. **TTL de aprovação 1h, intervalo 10 min, teto 6/h.** Rajada maior perde o
   excedente, e **essa é a falha segura**: o teto protege o canal de preço
   velho. Só mexer com decisão explícita do dono.
6. **O worker valida antes de enviar.** Mudou formato de post? **Publique o
   worker ANTES do coletor.** Ao contrário, todo post é recusado e o canal vai
   a zero. Já quase aconteceu em 11/11 e em 27/11.
7. **Guarda que não pode disparar é pior que guarda que dispara demais.** E
   alarme permanentemente aceso ensina o dono a ignorar o painel. Todo alarme
   novo precisa de um limiar que separe dinheiro parado de ruído.
8. **Nunca apontar sonda, log ou diagnóstico para `/users/me` do Mercado Livre**:
   devolve nome, CPF, endereço e telefone do dono.

## Protocolo entre agentes

**Toda alteração em produção vira registro no repositório, no mesmo dia.**

| se você… | então… |
|---|---|
| aplicar migração | use `apply_migration` (registra no histórico do Supabase) **e** commite o arquivo em `supabase/migrations/` |
| rodar SQL no SQL Editor | **avise no chat** — o SQL Editor NÃO registra no histórico, e o banco fica divergente do repo |
| publicar edge function | **busque a versão publicada antes** (`get_edge_function`), confira contra o repo, e só então publique. Já houve linha que existia só em produção |
| achar um problema | escreva em `docs/operacao-baixou.md` com **a medição**, não só a conclusão |
| desligar/ligar fonte, cron ou trava | diga no chat e no commit. São mudanças invisíveis no código |

**Mensagem de commit explica o PORQUÊ, com número.** "Corrige bug" não serve.
O padrão aqui é: o que foi medido, o que isso provou, o que mudou.

## Estado atual (27/11/2026)

- **Mercado Livre: DESLIGADO.** Em 23/11 17:22 o ML fechou
  `/products/{catálogo}/items` — era o último endpoint com preço de terceiros.
  403 `PA_UNAUTHORIZED_RESULT_FROM_POLICIES`. **Não é da nossa aplicação:** o
  projeto público `Maxwbh/Lista_de_Presentes` quebrou no mesmo dia, mesmo
  endpoint. 15 endpoints testados, nenhum devolve preço. A fonte foi desligada
  e **volta sozinha**: `sondar_acesso_ml()` roda a cada 10 min e religa ao ver 200.
- **Shopee: única fonte ativa.** Oscila entre 40% e 80% da capacidade normal
  (âncora fixa: 2400 itens/hora). Tem entregado 20 a 27 posts/dia.
- **Aviso de publicidade: `(ANÚNCIO)`** desde 27/11. O worker (v12) aceita os
  três formatos já usados; o coletor da Shopee **ainda não foi publicado** e
  segue produzindo o bloco antigo.
- **Pendente de publicação:** coletor da Shopee (traz `(ANÚNCIO)` e passa a
  gravar os códigos de erro da Shopee). Coletor do ML parado na v19.
- **Perda conhecida:** ~11 ofertas aprovadas/dia vencem antes de publicar, por
  rajada acima de 6/h. Decisão do dono pendente.

## Onde está escrito o resto

`docs/operacao-baixou.md` — todos os incidentes, com medição, causa e lição.
Leia antes de mexer em alarme, fila ou coletor. Cada seção existe porque
alguma coisa falhou calada.
