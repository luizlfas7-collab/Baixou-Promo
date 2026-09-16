# Baixou

Automação que observa preços de marketplace, pontua o que caiu de verdade e
publica no canal do Telegram [`@aixou_promocoes`](https://t.me/aixou_promocoes).
Projeto antes chamado **Sintonia**.

Não tem relação com o Radar Rota nem com o CRM de proteção veicular — são
projetos separados, com contas, bancos e canais próprios.

## Onde roda

| | |
|---|---|
| Supabase | projeto `baixou`, ref `xxskmxhpzbqzxoaffiul`, `sa-east-1` |
| Postgres | 17, com `pg_cron`, `pg_net`, `pgcrypto` e Vault |
| Edge Functions | `baixou-worker`, `baixou-ml-oauth`, `baixou-coletor-ml` |

## Estrutura

```
supabase/
  migrations/          na ordem em que foram aplicadas
  functions/
    baixou-ml-oauth/   conecta o Mercado Livre e guarda o token no cofre
    baixou-coletor-ml/ observa preço, pontua, enfileira
    baixou-worker/     publica no Telegram
    _compartilhado/    validação do post e allowlist de afiliados
```

## Como o motor funciona

```
itens_ml (watchlist)
     ↓  coletor, a cada 5 min
  ofertas → historico_precos
     ↓  desconto verificado contra o próprio histórico
 aprovacoes  (amarra payload + versão exata da oferta)
     ↓
fila_publicacao  (reserva por token, retentativa, raias)
     ↓  worker, a cada 2 min
 publicacoes
```

Apoio: `estado_destino` (reserva durável do canal), `credenciais_ml`,
`configuracoes` (linha única), `execucoes`, `erros`, `auditoria`, `perfis`.

Todas as tabelas têm RLS. O navegador só lê; quem escreve é o `service_role`,
usado pelas Edge Functions.

## As garantias que moram no banco

- **Impossível publicar conteúdo não aprovado.** `fila_publicacao` tem chave
  estrangeira composta para `aprovacoes` em
  `(aprovacao_id, oferta_id, hash_conteudo_oferta, hash_payload)`. Enfileirar
  payload diferente do aprovado é fisicamente impossível.
- **Um envio por destino por vez.** Advisory lock por `canal:destino` mais
  reserva durável em `estado_destino`.
- **Resultado desconhecido vira quarentena**, não retentativa. Se o despacho
  começou e não se sabe o desfecho, o canal trava até `reconciliar_destino`.
- **Renovação de token sob lease.** O refresh do ML é rotativo; duas renovações
  simultâneas matariam a conexão em silêncio.
- **Nada de credencial em `jsonb`** — `contem_dado_sensivel()` roda em CHECK.
- Todo post carrega `PUBLICIDADE • LINK DE AFILIADO`, e toda URL visível
  precisa ser de encurtador de afiliado da allowlist.

## Duas decisões que explicam o resto

**O desconto é o que nós observamos, não o que a loja diz.** O preço "de" que o
Mercado Livre exibe é ignorado. Uma oferta só é aprovada com duas ou mais
leituras a preços diferentes e queda de pelo menos 15%. Por isso o bot precisa
de tempo de observação antes de publicar qualquer coisa.

**A nota é calculada sobre o que deu para observar.** O denominador é a soma
dos pesos *disponíveis*; sinal ausente sai da conta em vez de valer zero. Peso
fixo com zero para o que falta é veneno: quando um endpoint do fornecedor muda,
o componente vira zero permanente e a coleta "funciona" publicando nada.

## O caminho de leitura do Mercado Livre

`/items/{id}` de anúncio de terceiro responde **403** para este tipo de
aplicação — com token, sem token, e com todas as permissões marcadas. Não é
credencial vencida.

O que funciona:

| Endpoint | Traz |
|---|---|
| `/products/{catálogo}/items` | preço, preço original, condição, frete, vendedor |
| `/products/{catálogo}` | título, foto, atributos |
| `/users/{vendedor}` | reputação |
| `/reviews/item/{id}` | avaliações |

Por isso a watchlist guarda o **id de catálogo**. Linha sem `item_id` segue o
vencedor da vitrine — que é o que o leitor vê ao clicar.

## Operação

```sql
select jsonb_pretty(public.painel());                -- o resumo de tudo
select jsonb_pretty(public.saude_da_coleta());       -- a coleta está viva?
select jsonb_pretty(public.ml_conexao_estado());     -- saúde da conexão
select jsonb_pretty(public.vistoria_para_soltar());  -- pré-condições
select jsonb_pretty(public.soltar_trava());          -- libera publicação
select public.puxar_trava();                         -- freio de mão
```

`saude_da_coleta()` é a primeira a consultar quando o canal ficar quieto. Ela
cruza **rodada** com **leitura de preço** de propósito: coletor que roda e não
lê é uma falha diferente de coletor que não roda, e as duas precisam aparecer.
Veredito `muda` significa mais de 20 minutos sem rodada — algo parou.

Cada rodada abre e fecha uma linha em `execucoes`, com contadores e motivo.
Rodada que morre no meio fica em `rodando` e a faxina a encerra como `falhou`
depois de 15 minutos, para que "penduradas" reflita problema de agora.

A trava de emergência é freio de **publicação**, não de observação: com ela
ligada o coletor continua formando histórico, só não enfileira.

## Observar e publicar são coisas separadas

O link de afiliado **não é necessário para observar**. Ele só faz falta na hora
de publicar.

Isso inverte o trabalho do operador. Exigir link no cadastro obrigava a gerar
link no escuro, antes de saber se o produto valia — e por isso a watchlist
ficou em 8 itens por semanas. Base pequena é o que mais limita resultado: o
Baixou só anuncia queda que ele mesmo viu, então oportunidade é função direta
de quantos produtos ele vigia.

Linha sem link observa, forma histórico e pontua igual. Quando passa do corte,
é carimbada em vez de enfileirada:

```sql
select * from public.ml_prontos_para_link();   -- já caiu, só falta o link
select public.ml_item_vincular('MLB00000000', 'https://meli.la/XXXXXXX');
```

Linha sem link **nunca chega à publicação**, por duas barreiras independentes:
o coletor nem tenta enfileirar, e a validação de payload recusaria a URL por
estar fora da allowlist. Uma bastaria; são duas porque publicar link errado no
canal é pior do que não publicar.

Cadastrar item:

```sql
-- Só observando (sem link)
select public.ml_item_observar('MLB00000000', 'Categoria', 'apelido');

-- Já com link, publica sozinho
select public.ml_item_cadastrar(
  'MLB00000000',              -- catálogo (obrigatório)
  'https://meli.la/XXXXXXX',  -- link de afiliado
  'Categoria', 'apelido',
  'MLB0000000000',            -- anúncio (opcional; sem ele, segue o vencedor)
  100                         -- prioridade
);
```

O id de catálogo está na URL pública de qualquer anúncio
(`mercadolivre.com.br/p/MLB…`). A busca da API (`/sites/MLB/search`) responde
403 nesta aplicação, com ou sem token — mesma parede do `/items`.

**Tempo de revisita** é o que decide se queda relâmpago é pega: o coletor lê 10
itens a cada 5 minutos, ou 120 por hora. Com 130 itens, cada um é olhado uma
vez por hora. Crescer a watchlist sem crescer o lote transforma revisita em
horas, e aí o preço já subiu quando o item volta a ser lido.

## A watchlist guarda mais de uma loja

`itens_ml` tem nome histórico: hoje ela guarda qualquer plataforma, e cada
linha diz de quem ela é na coluna `plataforma`. Isso não é organização, é
segurança de operação — **cada coletor só enxerga as linhas da sua
plataforma**. Sem esse filtro, o coletor do Mercado Livre pegaria um id de
Shopee, pediria ao `api.mercadolibre.com` um id que não é dele, tomaria erro e
queimaria `falhas_seguidas` até desabilitar a linha sozinho. O sintoma pareceria
defeito da fonte nova.

```sql
-- Mercado Livre: continua com as funções dele, que sabem das regras dele
select public.ml_item_observar('MLB00000000', 'Categoria', 'apelido');

-- Outras lojas
select public.watchlist_cadastrar('shopee', '22334455.99887766', null, 'Áudio', 'fone');
select public.watchlist_cadastrar('kabum', 'kbm-551122');

select * from public.watchlist_prontos_para_link();   -- já caiu, falta o link
select public.watchlist_vincular('kabum', 'kbm-551122', 'https://tidd.ly/XXXXXXX');
```

O ML exige id de **catálogo** e ainda é o único assim — por causa do 403 em
`/items`, a única porta de leitura dele é `/products/{catálogo}/items`. As
outras plataformas se identificam pelo próprio id do anúncio. Por isso
`watchlist_cadastrar` recusa `mercado_livre` de propósito, em vez de aceitar
pela metade.

Semear a fonte não liga coletor nenhum: as cinco linhas de `fontes` nascem
desabilitadas, e só o Mercado Livre tem coletor escrito. Shopee, KaBuM e Amazon
são, por enquanto, configuração à espera de código.

## Distribuição: a mesma oferta, fora do Telegram

O gargalo não é produção, é distribuição — em 7 dias, 24 posts geraram 3
cliques. Então nada aqui produz conteúdo novo: pega a oferta que **já foi
publicada** e veste ela para onde já existe gente. Quem posta é o dono, à mão.

```sql
select * from public.para_o_instagram(24);   -- o que merece Instagram, e em que formato
select * from public.para_compartilhar(24);  -- WhatsApp, Instagram feed e X
select public.resumo_do_dia(5);              -- "as melhores de hoje", pronto para encaminhar
select * from public.para_story(24);         -- Instagram stories
```

O link de afiliado é procurado em dois lugares, nesta ordem: na própria oferta
e depois na watchlist. Plataforma como a Shopee devolve o link junto com o
produto, e nesse caso ele mora em `ofertas.url_afiliado`; o Mercado Livre não
devolve, e aí vale o link cadastrado na watchlist.

### Por que story, e não feed

Na legenda do feed o link não clica — por isso o texto de feed manda para a
bio, o que custa um toque a mais e derruba quase todo o clique. **No story o
link clica**, pelo sticker de link, que desde 2021 vale para qualquer perfil.

O segundo motivo é menos óbvio e igualmente forte: **story expira em 24 horas,
e oferta também**. Post de feed com preço de promoção fica no grid para sempre
— semanas depois alguém entra, vê `R$ 899`, clica e encontra `R$ 1.299`. O
story se limpa sozinho, no mesmo ritmo em que a oferta morre.

`para_story()` devolve `link_do_sticker` numa coluna separada, e a `chamada`
**não contém URL nenhuma**. Não é estilo: URL digitada dentro do story não vira
link, então o leitor tenta tocar, não acontece nada, e o post inteiro passa
impressão de robô mal feito. O link vai no sticker; o texto só aponta para ele.

O story sobe à mão, e o sticker é colado à mão. A Graph API do Instagram
publica story mas **não publica sticker** — nem de link, nem de enquete.
Automatizar o envio produziria story sem link clicável, ou seja, exatamente o
que não gera comissão.

A coluna `o_preco` avisa quando o preço mudou desde o post do canal. Oferta
fora do ar não aparece; oferta que subiu aparece marcada e por último, porque a
`chamada` carrega o preço de hoje e continua correta — o que a alta muda é o
tamanho da notícia, não a veracidade dela.

### Social Score: nem tudo que vai ao canal merece Instagram

`social_score()` responde uma pergunta diferente da que o motor já respondeu.
O motor pergunta "isto é um bom negócio"; aqui a pergunta é "isto vira uma boa
imagem". **O corte já aconteceu** — só chega aqui o que foi publicado. Esta
nota decide distribuição, nunca qualidade.

A diferença entre as duas perguntas é a razão de a nota existir:

| | desconto | economia | como negócio | como post |
|---|---|---|---|---|
| Caneca R$ 29,90 | −40% | R$ 20 | bom | fraco |
| Geladeira R$ 1.700 | −15% | R$ 300 | ok | forte |

Por isso **economia em reais pesa mais que a porcentagem** (30 contra 22). O
número que faz parar de rolar a tela é quanto se deixa de gastar, não quantos
por cento.

Componentes: `economia` 30, `desconto` 22, `qualidade` 20 (a nota que o motor
já deu), `faixa_de_preco` 16 (compra por impulso mora entre R$ 40 e R$ 600),
`ineditismo` 12 (produto repetido cansa quem segue mais rápido do que cansa
quem lê canal).

**A comissão não entra.** Ela ordena a leitura e a fila, que é onde este
projeto decidiu que dinheiro manda. Aqui ela ficaria perto demais do corte:
bastaria uma oferta pior render mais para ganhar a vez.

Como em `pontuar()`, o denominador é a soma dos pesos **disponíveis** e há piso
de cobertura em 0,70. O piso não é decoração: sem ele uma oferta sem preço de
referência tirava **nota 100 com 23% de cobertura** — sobravam dois componentes,
os dois cheios por acaso, e a média deles dava o topo da lista. Nota confiante
feita de nada é pior que nota baixa.

Faixas — e não existe faixa de Reel, porque Reel não tem sticker de link e
premiar as melhores ofertas com o formato de menor conversão seria autossabotagem:

```
< 45  → so_o_canal     (não vai para o Instagram)
45-74 → story
>= 75 → story_e_feed
```

A nota ainda é **cega para desempenho**: não existe dado de clique no banco.
Quando houver rastreio, ele entra como componente novo e os pesos são
rebalanceados junto.

## Segredos

Nada de segredo neste repositório. O que precisa existir:

- Cofre do banco: `baixou_worker_cron_secret`, `baixou_ml_client_secret`,
  `baixou_ml_access_token`, `baixou_ml_refresh_token`
- Secrets da Edge Function: `TELEGRAM_BOT_TOKEN`

`SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` são injetados pelo Supabase.

## Conectar o Mercado Livre

No DevCenter, o `offline_access` **não se chama assim**: é a caixa
**"Refresh Token"** em *Editar → Configuração e scopes → Fluxos OAuth*. Sem
ela, o ML não emite refresh e a automação morreria a cada 6 horas.

Redirect: a própria URL da Edge Function `baixou-ml-oauth`. Não é preciso
domínio próprio.
