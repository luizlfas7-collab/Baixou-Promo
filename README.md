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
select jsonb_pretty(public.ml_conexao_estado());     -- saúde da conexão
select jsonb_pretty(public.vistoria_para_soltar());  -- pré-condições
select jsonb_pretty(public.soltar_trava());          -- libera publicação
select public.puxar_trava();                         -- freio de mão
```

A trava de emergência é freio de **publicação**, não de observação: com ela
ligada o coletor continua formando histórico, só não enfileira.

Cadastrar item:

```sql
select public.ml_item_cadastrar(
  'MLB00000000',              -- catálogo (obrigatório)
  'https://meli.la/XXXXXXX',  -- link de afiliado
  'Categoria', 'apelido',
  'MLB0000000000',            -- anúncio (opcional; sem ele, segue o vencedor)
  100                         -- prioridade
);
```

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
