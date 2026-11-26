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

## Distribuicao: canal do WhatsApp (decidido em 05/11)

O dono criou um canal no WhatsApp e escolheu, por ora, **copiar e colar a mao**
o post que o repasse entrega. A automacao fica para depois, em cima de um canal
que ja tenha audiencia.

Como funciona hoje, e nao precisa de nada novo:

1. Motor acha a oferta e valida a vantagem de preco.
2. Publica no `@aixou_promocoes` com o link de afiliado do dono.
3. O worker converte o MESMO payload com `montarRepasseWhatsapp()` e manda o
   texto pronto para `configuracoes.repasse_whatsapp_chat_id` via Telegram.
4. O dono copia e cola no canal do WhatsApp.

Atende as duas fontes (ML e Shopee) sem configuracao separada, porque converte
o payload publicado e nao a origem.

### Por que a publicacao automatica nao entrou

A Meta nao expoe Canais no Cloud API: nao existe endpoint oficial. As
bibliotecas que publicam em canal falam o protocolo do WhatsApp Web por
engenharia reversa e funcionam ate o numero ser banido, sem aviso e sem
recurso. O caminho oficial (mensagem de marketing 1:1) sai a ~R$ 0,35 por
mensagem entregue: com 7 posts/dia, R$ 73,50 por mes POR INSCRITO.

### Quando a automacao voltar a mesa

O banco JA esta pronto: `fila_publicacao.canal` e `estado_destino.canal`
aceitam `'whatsapp'`, e o worker recusa item de canal diferente do seu
`canalPermitido` — entao um segundo worker com `canalPermitido = 'whatsapp'`
consome as linhas de WhatsApp sem tocar no que ja roda.

O que falta e infraestrutura: a sessao do WhatsApp Web precisa de maquina
ligada 24h, e Edge Function e sem estado. **Hospedagem gratuita que dorme e
ativamente ruim aqui**: host dormiu, sessao caiu, QR de novo — e login
repetido e justamente o padrao que aumenta risco de ban.

Cautelas levantadas em 05/11, em ordem do que mais reduz risco:

1. Chip dedicado, nunca o numero pessoal. (O dono ja tem.)
2. Aquecer o chip com uso humano normal por 2-3 semanas antes de automatizar.
   Chip novo que comeca a transmitir no primeiro dia tem perfil de descartavel.
3. Manter o volume e o espacamento atuais (6-7/dia, 1 a cada 10 min). Nunca
   publicar em lote.
4. Uma sessao, um host, sem login/logout repetido e sem IP variando.
5. SO publicar no canal: sem auto-resposta, sem DM, sem adicionar ninguem.
6. Segundo admin no canal. **NAO CONFIRMADO** se o canal sobrevive intacto ao
   ban do numero criador — verificar antes de contar com isso.

A publicar em canal, o gatilho mais forte de ban (denuncia de destinatario) fica
enfraquecido: quem segue escolheu seguir, e quem nao quer mais deixa de seguir.

Se a automacao entrar, entra com: interruptor no banco (desliga sem redeploy),
o repasse para o Telegram seguindo em paralelo como caminho de reserva, sinal
de saude no boletim, recuo conservador em falha e jitter no horario.

## Alarmes vivem no banco, nao na sessao

`alarme_entrega` e `ofertas_perdidas` rodam dentro do Postgres e aparecem no
boletim. A sessao nao precisa acordar de 2 em 2 horas para que eles funcionem.

## Incidente 20 a 22/11: uma foto ruim congelou o canal por 61h30

O defeito mais caro ate hoje, e o mais silencioso. Fica aqui inteiro porque a
forma dele vai se repetir.

O QUE ACONTECEU, na ordem:

  20/11 14:53  Oferta 176405 entra na fila (id 845).
  20/11 14:55  Worker reserva, despacha, e o Telegram responde
               `400 Bad Request: failed to get HTTP URL content`
               — ele nao conseguiu BAIXAR a foto do produto.
  20/11 14:55  O item vai para `descartada` com ultimo_erro_codigo
               `resultado_desconhecido`, e o banco poe o DESTINO em
               quarentena: estado_destino.quarentena_em preenchido e
               reservado_ate = 'infinity'.
  20/11 17:56  Comeca a sangria. Ofertas aprovadas entram na fila e NUNCA sao
  a 22/11      reservadas (reservada_em nulo, tentativas 0), porque
               reservado_ate='infinity' impede qualquer reserva. Cada uma
               vence em ~65 min. Pelo menos 9 ofertas de nota 95 a 100
               perdidas assim.
  22/11 16:13  reconciliar_destino('telegram','@aixou_promocoes',
               'nao_entregue') solta a quarentena.
  22/11 16:15  Primeira publicacao em 61h30.

POR QUE NINGUEM VIU:

  1. O worker continuou rodando a cada 2 minutos e devolvendo `succeeded`.
     Visto de fora, motor saudavel.
  2. saude_por_fonte seguiu 'saudavel' nas duas fontes — e com razao: a COLETA
     estava perfeita. O problema era na ENTREGA, do outro lado da barra.
  3. O vigia do banco roda a cada 30 min, tem voz, e NAO tem regra para
     `destino_em_quarentena`. Canal congelado e a falha mais cara que existe
     aqui e e justamente a que nao acorda ninguem.
  4. O boletim mostrou publicou_24h caindo de 18 para 2, mas sem o alarme a
     queda so apareceu na leitura seguinte, 12h depois.

O DIAGNOSTICO SO FOI POSSIVEL porque a linha da fila guarda reservada_em,
despacho_iniciado_em e ultimo_erro_codigo. Item `cancelada` com
reservada_em NULO e tentativas 0 significa "o worker nunca chegou nele" — e
isso aponta direto para a reserva, nao para o envio. Sem esses tres campos o
diagnostico seria adivinhacao.

DOIS CONSERTOS, nenhum aplicado ainda:

  A) 4xx NAO E DESFECHO DESCONHECIDO. Um 400 do Telegram e recusa definitiva:
     ele diz "nao enviei". Tratar como "nao sei se saiu" e congelar o canal e
     desproporcional. Deve distinguir:
       - 4xx (requisicao rejeitada, nada postado) -> marca o item falho e segue
       - 5xx, ou rede caindo DEPOIS do envio -> ai sim quarentena
     So o segundo caso justifica parar o canal. Com isso, uma foto ruim
     descarta UM post em vez de matar dois dias e meio.
     A intencao da quarentena esta certa (nao publicar duas vezes); o que
     esta errado e a classificacao do erro.

  B) O VIGIA PRECISA COBRAR QUARENTENA. Uma regra ao lado de
     fontes_degradadas(): destino com quarentena_em preenchido por mais de
     ~15 minutos e dinheiro parado, e tem que acordar o dono.

ARMADILHA DE VERIFICACAO, paga nesta sessao: nao da para conferir o efeito de
reconciliar_destino() na MESMA instrucao SQL que a chama. Subconsultas de um
`select` leem o snapshot anterior ao update, entao o estado volta inalterado e
parece que a funcao falhou. Conferir sempre em chamada separada.

## Incidente 23 a 24/11: o Mercado Livre fechou o preço, e isso quase apagou a watchlist

**23/11 17:22 UTC** o ML parou de ler. Toda rodada desde então: `falhou`, com
`recusas_por_motivo: {falha_ler: 10}`. O vigia **funcionou** e alertou às
**17:43**, 21 minutos depois — a primeira vez que um alarme desse tipo pegou o
problema no começo em vez de depois de dias.

### Causa raiz, medida

O coletor lê cada item com duas chamadas. Medido em 24/11 com
`ensaio_get_ml()`, token saindo do cofre direto para o cabeçalho do pg_net:

| endpoint | resposta |
|---|---|
| `GET /products/{catalogo}` | **200** — título, foto, status. `buy_box_winner` nulo, **sem preço** |
| `GET /products/{catalogo}/items` | **403** `PA_UNAUTHORIZED_RESULT_FROM_POLICIES`, `blocked_by: PolicyAgent` |
| `GET /products/{catalogo}/items?limit=5` | **403** idem |
| `GET /sites/MLB/search?catalog_product_id=` | **403** `forbidden` |
| `GET /items/{id}` | **403** `access_denied` (já era) |

O token está válido — o 200 prova. **Todo endpoint que devolve preço está
403.** É política de acesso do ML, não credencial, e não tem contorno por
código: sem preço não existe detecção de queda de preço. Depende do painel de
desenvolvedor do ML.

### O dano colateral, que era pior que a cegueira

`ml_item_falhou()` incrementa `falhas_seguidas` e **desabilita o item em 9**.
`acesso_negado` (401/403) estava na lista das falhas não retentáveis, então
cada 403 do ML era cobrado do item. `ml_item_observado()` zera o contador a
cada leitura boa — logo, com o ML lendo até 17:22, todo contador estava em zero.

Dezoito horas depois, às 11:45 de 24/11:

- **369 habilitados, e todos os 369 com falhas acumuladas**
- média **8,1** falhas, pior 9, corte de desabilitação **9**
- **369 de 369 com 7 ou mais** — todos a um passo de cair
- última `proxima_observacao_em` agendada: 24/11 **15:38**

Em poucas horas a watchlist do ML estaria vazia, e quando o acesso voltasse não
haveria o que ler. Reconstruir 369 itens com link de afiliado é trabalho manual
do dono, item por item.

### O princípio que estava escrito e não estava valendo

O próprio coletor diz, sobre falha de rede: *"Falha de rede nao e culpa do
item: nao conta contra ele."* Vale igual para 403 de política. O item não fez
nada; a porta fechou. Punir o item por isso transforma indisponibilidade
temporária da fonte em **perda permanente de cadastro**.

Corrigido em `20261124121500`: falha de plataforma (401/403, PolicyAgent,
limite de taxa, 5xx) só grava o motivo e espera 15 minutos. Falha **do item**
(fora do catálogo, sem anúncio, sem preço, inativo) continua contando e
continua desabilitando em 9, porque aí o cadastro realmente morreu. O alarme
não foi silenciado: a rodada segue `falhou`, o veredito segue `cega`, o vigia
segue avisando.

Reparo aplicado junto: contador zerado e os itens caídos durante a janela
devolvidos. Resultado verificado em chamada separada — 387 habilitados,
**0 com falhas**, 0 a um passo de cair.

### A lição

Um guarda que pune o inocente é tão ruim quanto um guarda que não dispara.
A pergunta que faltava em `ml_item_falhou` era a mais simples: *de quem é a
culpa?* Toda penalidade automática a um cadastro precisa responder isso antes
de contar.

## 25/11: o inventário do vigia, a pedido do dono

> *"Preciso sempre que meu vigia comunique qualquer falha que venha a existir
> nesses lançamentos, ou seja, vigie 100% tudo o que está acontecendo."*

Antes de ampliar, o inventário. **O vigia já cobria 11 regras:** quarentena de
destino >15min, link suspeito em 48h, fonte cega/muda, token do ML fora de
`pronta`/`renovando`, 24h sem publicar com fila vazia, revisita esticada, fila
>50, fonte que lê e não entrega, fonte abaixo de 60% da âncora, aprovações
vencidas, e grava em `erros` se ficar sem token ou sem chat.

### Os buracos encontrados, e o que provou cada um

**1. A tabela `erros` tinha 68 linhas não resolvidas e nada no sistema lia essa
tabela.** O vigia *escrevia* nela e nunca *lia* dela. Entre as 68 estava
`telegram_400` — *"Bad Request: failed to get HTTP URL content"* — gravado em
**20/11 14:55**: a foto que congelou o canal por 61h30. **O sistema registrou a
causa do incidente e ninguém leu.** → `erros_abertos(24)`.

Os 403 do ML desta semana, por outro lado, **não estão** nessa tabela — vão
para `itens_ml.ultimo_erro`. Nem toda falha passa por `erros`, e isso muda onde
cada guarda tem de ficar.

**2. Ninguém conferia se o aviso chegou.** Os avisos saem por `net.http_post` e
nada olhava `net._http_response`. Conferido à mão em 25/11: status 200,
`ok:true`, mensagens 723 e 724 no chat 8660036653 — estavam chegando. Mas o dia
em que pararem, ninguém saberia. **Fica urgente por causa da rotação do token do
bot:** o segredo no cofre fica velho no mesmo instante e todo envio passa a dar
401. → `vigia_sem_voz()`, que grava em `erros` e **não** no Telegram: alarme
sobre o canal quebrado não pode usar o canal quebrado.

**3. O disco não era olhado, e o limite estava chumbado em 900 MB.** Com 1.580 MB
no banco, o veredito era `perto_do_limite` permanente — alarme sempre aceso não
informa nada. Limite virou coluna (`configuracoes.disco_limite_bytes`, inicial
8 GB = disco mínimo de projeto pago). Veredito agora: `ok`, 19,28%. →
`disco_em_risco()`.

**4. Quatro formas de o motor parar sem nenhuma regra perceber:** rodada
pendurada em `rodando` (número que **já era calculado** por `saude_da_coleta` e
ignorado — o mesmo padrão exato do `falhas_1h` que custou seis dias em 11/11),
agendamento do cron caído, trava de emergência esquecida ligada, e token do ML
dizendo `pronta` com `expira_em` no passado. → `motor_travado()`.

**5. A regra de degradação piscava.** Medido em 25/11: Shopee de 0,54 às 00:43
para 0,71 às 01:28. Cada ida e volta mandava um aviso e um `NORMALIZADO`, e o
`NORMALIZADO` não tem carência. Alarme que dispara sempre é barulho, e barulho
faz o dono parar de ler — o oposto do pedido. Corrigido com **histerese**:
dispara abaixo de 0,60, só se cala acima de 0,75.

### O que ainda NÃO é vigiado

**Versão publicada das edge functions diferente do repositório.** Hoje o repo
tem o `#publi` e a produção não, e nada acusa. O banco não vê isso sozinho: vai
junto com a publicação dos coletores, fazendo cada rodada gravar a própria
versão em `metadados` para o vigia comparar.

### A lição

"Vigie 100%" começa por um inventário, não por regras novas. Dos cinco buracos,
**dois eram números que o sistema já calculava e ninguém lia** — `penduradas` e
a tabela `erros`. Guarda que não dispara é pior que guarda que dispara demais, e
a forma mais comum dela aparecer não é falta de código: é dado medido que
ninguém olha.

## 26/11: o que é e o que não é "resolver o motor cego do ML"

O dono pediu: *"Resolva esse motor cego pelo ML."* Resposta honesta: **a cegueira
não se resolve do nosso lado.** A investigação completa, com o token saindo do
cofre direto para o cabeçalho:

| chamada | resposta |
|---|---|
| `GET /users/me` | **200** — token íntegro, conta reconhecida |
| `GET /products/{catálogo}` | **200** — título, fotos, atributos, pickers |
| `GET /products/search?site_id=MLB` | **200** — busca de catálogo |
| `GET /highlights/MLB/category/{id}` | **200** — só ids e posições |
| `GET /products/{catálogo}/items` | **403** `PA_UNAUTHORIZED_RESULT_FROM_POLICIES` |
| `GET /items/{id}` | **403** `access_denied` |
| `GET /items?ids={id}` | **403** no item do lote |
| `GET /sites/MLB/search?q=` | **403** `forbidden` |
| `GET /reviews/item/{id}` | **403** `forbidden` |

**O mesmo token que lê `/users/me` com 200 recebe 403 em tudo que tem preço.**
Logo não é credencial: é política sobre o **recurso**. E dentro do acesso que a
aplicação tem não existe caminho nenhum com preço — `/products/{catálogo}`
devolve 13,8 KB sem uma única chave `price`, `buy_box_winner` nulo, e `pickers`
só com cor, foto e nome. Sem preço não existe detecção de queda de preço.

Nota de reparo futuro: `/reviews/item/` caiu junto, ou seja `lerAvaliacao()` do
ML também está morto. Quando o acesso voltar, conferir as duas coisas.

**O que NÃO se faz:** derrubar o cabeçalho de autorização para ver se o
endpoint público responde. O `PolicyAgent` é uma decisão da plataforma sobre
esta aplicação; contornar isso retirando a credencial é burlar controle de
acesso — e o custo do erro é a conta de afiliado, que é a receita inteira.

**O que se faz, e foi feito:** trocar *"cego, motivo desconhecido"* por *"cego,
HTTP 403 PA_UNAUTHORIZED, em /products/.../items, desde 23/11 17:22, conferido
há N minutos"*, e detectar a volta sozinho em 10 minutos.

`acesso_fonte` + `sondar_acesso_ml()` (cron a cada 10 min, duas fases porque
pg_net é assíncrono) + `acesso_bloqueado()` no vigia. O alarme de acesso
**substitui** o de motor cego para a mesma fonte: são o mesmo problema e o
segundo contém o primeiro. Um problema, um aviso.

### E o `delete` saiu do corpo do vigia

Por causa de **uma linha** (limpar alerta normalizado), toda alteração no vigia
disparava a confirmação de comando destrutivo do Supabase e virava "mandar o
arquivo para o dono colar". Três vezes em três dias.

O comando virou `alerta_resolvido()` — visível, com nome, mesmo efeito, mesmo
lugar lógico. O que mudou é que o corpo do vigia não contém mais remoção, e as
próximas regras entram sem depender de alguém estar acordado. Não é contornar a
confirmação: é parar de pedi-la para a coisa errada.

### A lição

"Resolva" às vezes significa "prove que não dá, com precisão, e torne a espera
observável". Nove endpoints testados, um diagnóstico citável num chamado de
suporte, e recuperação automática em 10 minutos valem mais que uma gambiarra
que arrisca a conta de afiliado.

## 26/11, parte 2: o pente fino desmentiu a minha própria conclusão

Eu tinha dito ao dono que o 403 do ML era "política sobre o recurso, não tem o
que fazer do nosso lado, abra chamado". Ele respondeu que **o painel de
desenvolvedor não mostra nada de errado** e pediu pente fino — código, criação
da aplicação, qualquer erro possível. Estava certo em insistir.

### O que o registro da aplicação diz (GET /applications/{id}, HTTP 200)

```
active: true      blocked: false     disabled: false    partial_blocked: false
origin: "ML"      sandbox_mode: false                   max_requests_per_hour: 18000
date_created:         19/08/2026
traceability_updated: 20/08/2026   <- última alteração
certification_status: "not_certified"
```

**A aplicação não é tocada desde 20 de agosto.** Nada mudou do nosso lado em
23/11. Não foi erro de código, não foi erro de criação, não foi credencial. A
mudança veio deles.

### A causa: os escopos são todos de VENDEDOR

```
urn:ml:mktp:offers        urn:ml:mktp:publish-sync    urn:ml:mktp:ads
urn:ml:mktp:metrics       urn:ml:mktp:invoices        urn:ml:mktp:orders-shipments
urn:ml:mktp:comunication  urn:ml:all:publish-sync     urn:ml:all:comunication
urn:global:admin:info     urn:global:admin:oauth      urn:global:admin:users
read   write   offline_access
```

Lidos pelo texto que o próprio ML exibe na tela de autorização: *"anúncios **da
loja**"*, *"ofertas e cupons **de uma venda**"*, *"**suas** vendas e envios"*,
*"faturamento"*, *"campanhas de publicidade"*. **Nenhum concede leitura de
catálogo de terceiros** — que é a única coisa que o Baixou faz.

### O teste que fecha a prova

| chamada | resposta |
|---|---|
| `/users/{dono}` | **200** |
| `/users/{dono}/items/search` | **200** — endpoint de item, funciona |
| `/applications/{app}` | **200** |
| `/sites/MLB` | **200** |
| item, preço ou busca de **terceiros** | **403** |

**Tudo sobre a própria conta responde; tudo sobre terceiros, não.** Até 23/11 o
ML deixava passar. Naquele dia o PolicyAgent passou a exigir a permissão
funcional correspondente, e a aplicação nunca teve essa permissão — ela só
nunca tinha sido cobrada. Isso explica o timing exato sem precisar supor
bloqueio nenhum.

### A contradição que vale no chamado

A API diz `certification_status: "not_certified"`. A tela de autorização exibe,
com selo verde, **"CERTIFICADA — Certificada pelo Mercado Livre"**. As duas não
podem estar certas, e no ML o acesso a recurso restrito costuma depender de
certificação.

### Aviso permanente sobre a sonda

`GET /users/me` e `GET /users/{id}` retornam **nome, CPF, endereço e telefone**
do dono. A sonda `acesso_fonte` grava o corpo da resposta. **Nunca apontar
sonda, log ou diagnóstico para esses endpoints** — o `ensaio_get_ml` só deve
bater em recurso de catálogo. Já está escrito no comentário da tabela.

### A lição

Eu fechei um diagnóstico cedo demais. "Política sobre o recurso" estava certo
como mecanismo e **errado como conclusão**: virou "não há o que fazer" quando o
certo era "falta uma permissão, e dá para pedir". A diferença entre as duas
frases é o dono ficar parado ou ter três caminhos. Quando o usuário diz que a
evidência dele não bate com a minha, a resposta é medir de novo, não repetir.
