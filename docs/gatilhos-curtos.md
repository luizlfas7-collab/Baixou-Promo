# Prompts curtos das rotinas agendadas

Para colar no lugar dos prompts atuais. Cada disparo hoje reinjeta ~2.500
palavras de instrucao e historico; com 14 disparos/dia isso da cerca de
**35 mil tokens por dia de texto repetido**, antes de qualquer trabalho ser
feito. O conteudo todo esta em `docs/operacao-baixou.md` e passa a ser lido
so quando faz falta.

---

## 1. Boletim 2x/dia (07:52 e 20:52 de Brasilia) — SUBSTITUIR POR:

```
Boletim do Baixou. Este SEMPRE escreve, mesmo com tudo bem: o dono pediu
constancia, nao susto.

RODAR — uma chamada, e so:
  select public.boletim();

Antes de relatar, ler docs/operacao-baixou.md no repositorio (branch
claude/continuing-from-desktop-sfgx1d): regras, armadilhas, numeros que nao se
mexe, e o que depende do dono. Nao reinvestigar o que esta listado como fechado.

FORMATO (curto, portugues, sem jargao):
1. PUBLICOU — quantos em 24h e nas ultimas 13h, com o desconto real do
   snapshot. Se zero, dizer e explicar por que.
2. FUNIL DE LINKS — sempre presente, mesmo vazio. Por desconto, com catalogo,
   nota e pagina. Comparar com o boletim anterior: item que saiu da lista sem
   link gerado e dinheiro que passou — dizer qual era e quanto valia.
3. QUEBROU — so o que esta fora do normal. Se nada, "nada quebrou".
4. CONSERTEI — o que foi feito sozinho desde o ultimo boletim. Se nada, omitir.
5. PRECISO DE VOCE — lista curta. Se nada, omitir.

Consertar sozinho antes de relatar e commitar na branch
claude/continuing-from-desktop-sfgx1d. Tudo que dependa do dono vai com passos
numerados, onde clicar, e o PORQUE.

Se a consulta nao rodar, ESCREVER MESMO ASSIM com a ultima medicao confirmada,
rotulada com a hora exata. Ficar calado e falha, nao silencio.
```

---

## 2. Vigia mudo de 2h — RECOMENDACAO: DESLIGAR

**Por que:** ele e mudo por desenho e quase nunca fala. O boletim 2x/dia le
exatamente os mesmos numeros. E a protecao real — `alarme_entrega` e
`ofertas_perdidas` — roda **dentro do Postgres**, nao na sessao: ela nao precisa
acordar de 2 em 2 horas para que esses alarmes funcionem.

Hoje ele custa 12 disparos/dia para, na pratica, nao dizer nada. Um vigia que
nunca grita e despesa, nao protecao.

**Se preferir manter alguma vigilancia entre boletins**, trocar o cron para cada
6h (`0 */6 * * *`) e usar este texto:

```
Vigia mudo do Baixou. Rodar sempre, falar quase nunca.

RODAR:
  select public.boletim();

Escrever ao dono SO em tres casos:
1. DINHEIRO — link.ok < link.publicacoes. Mandar as suspeitas (id e URL).
2. CEGUEIRA — veredito 'cega' ou 'muda' em qualquer fonte; token fora de
   pronta/renovando ou geracao parada ha mais de 8h; publicou_24h = 0 com fila
   0 em dois check-ins seguidos; alarme_entrega com conteudo.
3. SANGRIA — ofertas_perdidas com conteudo.

Em qualquer outro caso, encerrar em silencio — mas a consulta TEM de rodar.
Encerrar o turno depois de so carregar a ferramenta e falha, nao silencio.

Regras, armadilhas e o que nao reinvestigar: docs/operacao-baixou.md.
'vigia_mudo' e estado conhecido, nao alarmar por ele.
```

---

## Passo a passo para aplicar

1. **Abrir a lista de tarefas agendadas** da conta (onde os dois gatilhos do
   Baixou aparecem). *Por que:* o prompt vive guardado la, nao no repositorio —
   eu nao consigo reescrever um gatilho que exige aprovacao do dono.
2. **No "Boletim Baixou 2x/dia", apagar o prompt inteiro e colar o bloco 1.**
   *Por que:* corta ~2.300 palavras por disparo, 2 vezes por dia, sem perder
   nenhuma regra — elas foram para o arquivo.
3. **No "Vigia mudo do Baixou", desligar a rotina** (ou trocar o cron para
   `0 */6 * * *` e colar o bloco 2). *Por que:* 12 disparos/dia de um alarme que
   nao dispara. O ganho aqui e o maior dos tres.
4. **Comecar uma sessao NOVA do Claude Code** depois disso. *Por que:* esta
   sessao roda desde setembro e ja foi comprimida varias vezes; cada compressao
   reescreve um resumo grande. O estado do projeto vive no banco e no
   repositorio, nao no chat. E o `.claude/settings.json` com a allowlist so
   passa a valer a partir de uma sessao nova — resolve duas coisas de uma vez.
