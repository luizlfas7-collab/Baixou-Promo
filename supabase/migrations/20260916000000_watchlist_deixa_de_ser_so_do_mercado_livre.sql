-- Watchlist deixa de ser so do Mercado Livre
--
-- A watchlist nasceu colada no ML: id em formato MLB no CHECK, leitura sem
-- filtro de plataforma, e o pacote de compartilhamento procurando o link de
-- afiliado so em itens_ml. Com uma fonte so, nada disso incomoda.
--
-- Na primeira linha de outra plataforma, tres coisas quebram de uma vez:
--
--   1. O CHECK recusa o id, porque nem Shopee nem KaBuM chamam anuncio de MLB.
--
--   2. Se o id passasse, `ml_itens_para_observar` entregaria essa linha ao
--      coletor do ML, que pediria ao api.mercadolibre.com um id que nao e
--      dele, tomaria erro e queimaria `falhas_seguidas` ate desabilitar a
--      linha sozinho. O coletor errado envenenando a linha certa e a falha
--      mais cara daqui: parece defeito da fonte nova, e nao e.
--
--   3. `para_compartilhar` e `resumo_do_dia` descartariam a oferta em
--      silencio. Os dois procuram o link em itens_ml, e ha plataforma que
--      entrega o link de afiliado junto com a propria oferta — a Shopee e
--      assim. Nesse caso o link mora em `ofertas.url_afiliado`, coluna que ja
--      existe desde o primeiro dia e que ninguem le.
--
-- Isto aqui nao traz fonte nova e nao liga nada. Tira do caminho o que
-- impediria a proxima, para que o segundo coletor seja um coletor e nao uma
-- segunda copia da pilha do ML.

-- ---------------------------------------------------------------------------
-- De que plataforma e esta linha
--
-- Mesmo vocabulario de `fontes.plataforma`, de proposito: watchlist e fonte
-- divergirem seria uma traducao a mais para errar no meio do caminho.
-- ---------------------------------------------------------------------------

alter table public.itens_ml
  add column if not exists plataforma text not null default 'mercado_livre';

alter table public.itens_ml drop constraint if exists itens_ml_plataforma_ck;
alter table public.itens_ml add constraint itens_ml_plataforma_ck
  check (plataforma in (
    'mercado_livre', 'shopee', 'kabum', 'amazon', 'manual', 'outro'
  ));

comment on column public.itens_ml.plataforma is
  'De quem e o id desta linha. Decide qual coletor pode le-la; sem isto o coletor do ML tenta ler id dos outros e desabilita a linha por falha.';

comment on table public.itens_ml is
  'Watchlist de todas as plataformas. O nome e historico: nasceu so do Mercado Livre.';

-- ---------------------------------------------------------------------------
-- Formato de id deixa de ser global e passa a ser da plataforma
--
-- O `^MLB[0-9]+$` continua valendo — para as linhas do ML, onde ele e
-- verdade. Para as outras, so um limite de tamanho: inventar formato para
-- plataforma que ainda nao tem coletor seria adivinhar.
-- ---------------------------------------------------------------------------

alter table public.itens_ml drop constraint if exists itens_ml_item_ck;
alter table public.itens_ml add constraint itens_ml_item_ck
  check (
    item_id is null
    or case plataforma
         when 'mercado_livre' then item_id ~ '^MLB[0-9]{6,20}$'
         else char_length(btrim(item_id)) between 1 and 120
       end
  );

alter table public.itens_ml drop constraint if exists itens_ml_catalogo_ck;
alter table public.itens_ml add constraint itens_ml_catalogo_ck
  check (
    produto_catalogo is null
    or case plataforma
         when 'mercado_livre' then produto_catalogo ~ '^MLB[0-9]{6,20}$'
         else char_length(btrim(produto_catalogo)) between 1 and 120
       end
  );

-- ---------------------------------------------------------------------------
-- O link de afiliado deixa de ser obrigado a ser do Mercado Livre
--
-- `20260822040000` quis afrouxar esta regra e soltou `itens_ml_url_afiliado_ck`
-- — nome que nunca existiu. O `drop constraint IF EXISTS` engoliu o engano sem
-- reclamar, a constraint nova entrou ao lado da antiga, e a antiga continuou
-- valendo ate hoje:
--
--   CHECK (url_afiliado ~ '^https://meli\.la/[A-Za-z0-9]{4,32}$')
--
-- Com uma loja so, ninguem percebe: todo link do ML e meli.la mesmo. O
-- primeiro link de Shopee ou de Awin bateria nela, e o erro apontaria para uma
-- constraint que a migration seguinte "ja tinha removido".
--
-- Fica valendo a regra larga que 20260822040000 pretendia: https e tamanho.
-- Larga de proposito — a allowlist de encurtador que decide o que pode
-- aparecer para o leitor mora em `_compartilhado/afiliados.ts`, na hora de
-- publicar. Copiar a allowlist para ca criaria duas verdades para divergirem.
-- ---------------------------------------------------------------------------

alter table public.itens_ml drop constraint if exists itens_ml_afiliado_ck;

-- O catalogo continua obrigatorio no ML, e isso nao e preferencia: `/items`
-- responde 403 para anuncio de terceiro nesta aplicacao, entao a unica porta
-- de leitura e `/products/{catalogo}/items`. Linha do ML sem catalogo seria
-- linha que ninguem consegue ler. Nas outras plataformas basta ter algum
-- alvo.
alter table public.itens_ml drop constraint if exists itens_ml_precisa_de_alvo_ck;
alter table public.itens_ml add constraint itens_ml_precisa_de_alvo_ck
  check (
    case plataforma
      when 'mercado_livre' then produto_catalogo is not null
      else coalesce(item_id, produto_catalogo) is not null
    end
  );

-- Identidade passa a incluir a plataforma. Sem isso, um id que por acaso se
-- repita entre duas lojas viraria colisao de chave — e o segundo cadastro
-- sobrescreveria o primeiro em vez de existir ao lado dele.
drop index if exists public.itens_ml_identidade_idx;
create unique index if not exists itens_ml_identidade_idx
  on public.itens_ml (plataforma, coalesce(item_id, produto_catalogo));

-- ---------------------------------------------------------------------------
-- Quem inseria por `on conflict` precisa apontar para o indice novo
--
-- `on conflict (expressao)` so encontra o indice se a expressao bater exatamente
-- com a dele. Trocar a identidade sem tocar aqui derrubaria as duas portas de
-- entrada da watchlist com "no unique or exclusion constraint matching" — o
-- cadastro a mao e a descoberta automatica, as duas de uma vez.
-- ---------------------------------------------------------------------------

create or replace function public.ml_item_cadastrar(
  p_produto_catalogo text,
  p_url_afiliado text,
  p_categoria text default 'Ofertas gerais'::text,
  p_apelido text default null::text,
  p_item_id text default null::text,
  p_prioridade smallint default 100
)
returns bigint
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_catalogo text := nullif(upper(btrim(coalesce(p_produto_catalogo, ''))), '');
  v_item text := nullif(upper(btrim(coalesce(p_item_id, ''))), '');
  v_link text := nullif(btrim(coalesce(p_url_afiliado, '')), '');
  v_id bigint;
begin
  if v_catalogo is null then
    raise exception 'Produto de catalogo e obrigatorio: sem ele nao ha como ler preco'
      using errcode = '22023';
  end if;

  insert into public.itens_ml
    (plataforma, item_id, url_afiliado, categoria, apelido, produto_catalogo, prioridade)
  values (
    'mercado_livre', v_item, v_link, coalesce(p_categoria, 'Ofertas gerais'),
    p_apelido, v_catalogo, greatest(least(coalesce(p_prioridade, 100), 1000), 0)
  )
  on conflict (plataforma, coalesce(item_id, produto_catalogo)) do update
    -- coalesce e nao excluded direto: recadastrar sem link nao pode APAGAR um
    -- link que ja existia. Perder link de item que ja publica seria um estrago
    -- silencioso.
    set url_afiliado = coalesce(excluded.url_afiliado, public.itens_ml.url_afiliado),
        categoria = excluded.categoria,
        apelido = coalesce(excluded.apelido, public.itens_ml.apelido),
        produto_catalogo = excluded.produto_catalogo,
        prioridade = excluded.prioridade,
        habilitado = true,
        falhas_seguidas = 0,
        ultimo_erro = null,
        proxima_observacao_em = now()
  returning id into v_id;

  return v_id;
end;
$$;

-- A descoberta varre pagina do Mercado Livre atras de id de catalogo, entao
-- tudo que ela insere nasce do ML. Passa a dizer isso em vez de deixar
-- implicito no default da coluna.
create or replace function public.descoberta_coletar(p_limite_novos integer default 15)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_pendente record;
  v_corpo text;
  v_status integer;
  v_encontrados integer;
  v_inseridos integer;
  v_total_novos integer := 0;
  v_paginas integer := 0;
  v_espaco integer;
begin
  v_espaco := public.watchlist_teto() - (select count(*) from public.itens_ml where habilitado);
  if v_espaco <= 0 then
    return jsonb_build_object('situacao', 'watchlist_cheia', 'teto', public.watchlist_teto());
  end if;

  v_espaco := least(v_espaco, greatest(0, coalesce(p_limite_novos, 15)));

  for v_pendente in
    select * from public.descobertas_pendentes
    where processada_em is null
    order by pedida_em
    limit 10
  loop
    select r.status_code, r.content into v_status, v_corpo
    from net._http_response r where r.id = v_pendente.pedido_id;

    if not found then
      if v_pendente.pedida_em < now() - interval '1 hour' then
        update public.descobertas_pendentes
        set processada_em = now(), encontrados = -1, inseridos = 0
        where id = v_pendente.id;
      end if;
      continue;
    end if;

    v_paginas := v_paginas + 1;
    v_encontrados := 0;
    v_inseridos := 0;

    if v_status = 200 and v_corpo is not null then
      with achados as (
        select distinct m[1] as catalogo
        from regexp_matches(v_corpo, '/p/(MLB[0-9]{6,})', 'g') as m
      ),
      novos as (
        select a.catalogo from achados a
        where not exists (
          select 1 from public.itens_ml i
          where i.plataforma = 'mercado_livre' and i.produto_catalogo = a.catalogo
        )
        limit v_espaco
      ),
      gravados as (
        insert into public.itens_ml
          (plataforma, item_id, url_afiliado, categoria, apelido, produto_catalogo, prioridade, proxima_observacao_em)
        select 'mercado_livre', null, null, 'Descoberta', null, n.catalogo, 50, now()
        from novos n
        on conflict (plataforma, coalesce(item_id, produto_catalogo)) do nothing
        returning 1
      )
      select
        (select count(*) from achados),
        (select count(*) from gravados)
      into v_encontrados, v_inseridos;

      v_espaco := v_espaco - v_inseridos;
      v_total_novos := v_total_novos + v_inseridos;
    end if;

    update public.descobertas_pendentes
    set processada_em = now(), encontrados = v_encontrados, inseridos = v_inseridos
    where id = v_pendente.id;

    exit when v_espaco <= 0;
  end loop;

  return jsonb_build_object(
    'situacao', 'ok',
    'paginas_lidas', v_paginas,
    'produtos_novos', v_total_novos,
    'watchlist', (select count(*) from public.itens_ml where habilitado),
    'sem_link', (select count(*) from public.itens_ml where habilitado and url_afiliado is null),
    'teto', public.watchlist_teto()
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Leitura passa a ser por plataforma
--
-- Este e o filtro que impede o coletor do ML de pegar linha que nao e dele.
-- ---------------------------------------------------------------------------

create or replace function public.watchlist_para_observar(
  p_plataforma text default 'mercado_livre',
  p_limite smallint default 5
)
returns table (
  id bigint,
  item_id text,
  url_afiliado text,
  categoria text,
  produto_catalogo text
)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_plataforma text := coalesce(nullif(btrim(p_plataforma), ''), 'mercado_livre');
  v_intervalo integer;
  v_limite smallint;
begin
  -- Intervalo da fonte habilitada daquela plataforma. Fonte desligada nao
  -- interrompe a observacao: o intervalo so decide quando a linha vence de
  -- novo, e observar e de graca. Quem freia publicacao e a trava.
  select min(f.intervalo_coleta_segundos) into v_intervalo
  from public.fontes f
  where f.plataforma = v_plataforma
    and f.habilitada;

  v_intervalo := coalesce(v_intervalo, 300);
  v_limite := greatest(1, least(coalesce(p_limite, 5), 20));

  return query
  with vencidos as (
    select i.id
    from public.itens_ml i
    where i.habilitado
      and i.plataforma = v_plataforma
      and coalesce(i.item_id, i.produto_catalogo) is not null
      and i.proxima_observacao_em <= now()
    order by
      i.proxima_observacao_em,
      -- Quem tem link ganha a disputa: so ele pode virar comissao.
      (i.url_afiliado is not null) desc,
      i.prioridade desc,
      i.id
    limit v_limite
    for update skip locked
  )
  update public.itens_ml i
    set proxima_observacao_em = now() + make_interval(secs => v_intervalo)
    from vencidos v
    where i.id = v.id
    returning i.id, i.item_id, i.url_afiliado, i.categoria, i.produto_catalogo;
end;
$$;

comment on function public.watchlist_para_observar(text, smallint) is
  'Lote de itens vencidos de UMA plataforma. O filtro por plataforma e o que impede um coletor de ler id que nao e dele.';

-- O coletor do ML ja esta no ar chamando este nome. Ele continua existindo e
-- continua devolvendo as mesmas colunas — agora com a garantia de so trazer
-- linha do ML. Trocar a assinatura aqui exigiria deploy sincronizado da Edge
-- Function, e nao ha motivo para pagar isso.
create or replace function public.ml_itens_para_observar(p_limite smallint default 5)
returns table (
  id bigint,
  item_id text,
  url_afiliado text,
  categoria text,
  produto_catalogo text
)
language sql
security definer
set search_path to ''
as $$
  select * from public.watchlist_para_observar('mercado_livre', p_limite);
$$;

comment on function public.ml_itens_para_observar(smallint) is
  'Lote do Mercado Livre. Hoje e so um apelido de watchlist_para_observar(''mercado_livre'', ...), mantido porque o coletor no ar chama por este nome.';

-- ---------------------------------------------------------------------------
-- Cadastro das outras plataformas
--
-- O ML continua com `ml_item_cadastrar` / `ml_item_observar`, que sabem das
-- regras dele (catalogo obrigatorio, id em MLB). Esta aqui e a porta das
-- demais, e recusa o ML de proposito em vez de aceitar pela metade.
-- ---------------------------------------------------------------------------

create or replace function public.watchlist_cadastrar(
  p_plataforma text,
  p_item_id text,
  p_url_afiliado text default null,
  p_categoria text default 'Ofertas gerais',
  p_apelido text default null,
  p_prioridade smallint default 100
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_plataforma text := lower(nullif(btrim(coalesce(p_plataforma, '')), ''));
  v_item text := nullif(btrim(coalesce(p_item_id, '')), '');
  v_link text := nullif(btrim(coalesce(p_url_afiliado, '')), '');
  v_id bigint;
begin
  if v_plataforma is null or v_item is null then
    return jsonb_build_object('ok', false, 'motivo', 'plataforma_e_item_sao_obrigatorios');
  end if;

  if v_plataforma = 'mercado_livre' then
    return jsonb_build_object(
      'ok', false,
      'motivo', 'use_ml_item_cadastrar',
      'detalhe', 'O ML precisa do id de catalogo, nao do anuncio. A funcao dele sabe disso.'
    );
  end if;

  if v_plataforma not in ('shopee', 'kabum', 'amazon', 'manual', 'outro') then
    return jsonb_build_object('ok', false, 'motivo', 'plataforma_desconhecida');
  end if;

  insert into public.itens_ml (
    plataforma, item_id, url_afiliado, categoria, apelido, prioridade
  )
  values (
    v_plataforma,
    v_item,
    v_link,
    coalesce(nullif(btrim(coalesce(p_categoria, '')), ''), 'Ofertas gerais'),
    nullif(btrim(coalesce(p_apelido, '')), ''),
    coalesce(p_prioridade, 100)
  )
  on conflict (plataforma, coalesce(item_id, produto_catalogo)) do update
    set url_afiliado = coalesce(excluded.url_afiliado, public.itens_ml.url_afiliado),
        categoria = excluded.categoria,
        apelido = coalesce(excluded.apelido, public.itens_ml.apelido),
        prioridade = excluded.prioridade,
        habilitado = true,
        atualizado_em = now()
  returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'id', v_id,
    'plataforma', v_plataforma,
    'item', v_item,
    'tem_link', v_link is not null
  );
end;
$$;

comment on function public.watchlist_cadastrar(text, text, text, text, text, smallint) is
  'Poe item de outra plataforma na watchlist. Sem link ele observa e forma historico igual; o link so faz falta na hora de publicar.';

-- ---------------------------------------------------------------------------
-- Vincular e listar, sem assumir Mercado Livre
-- ---------------------------------------------------------------------------

create or replace function public.watchlist_vincular(
  p_plataforma text,
  p_id_do_item text,
  p_url_afiliado text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_plataforma text := lower(nullif(btrim(coalesce(p_plataforma, '')), ''));
  v_item text := nullif(btrim(coalesce(p_id_do_item, '')), '');
  v_link text := nullif(btrim(coalesce(p_url_afiliado, '')), '');
  v_id bigint;
begin
  if v_plataforma is null or v_item is null or v_link is null then
    return jsonb_build_object('ok', false, 'motivo', 'plataforma_item_e_link_sao_obrigatorios');
  end if;

  -- O ML guarda o alvo em produto_catalogo e escreve id em caixa alta; as
  -- outras plataformas guardam em item_id. Aceita os dois lados para nao
  -- obrigar quem chama a saber onde cada uma mora.
  update public.itens_ml
  set url_afiliado = v_link,
      pronto_em = null,
      pronto_pontuacao = null,
      pronto_desconto = null,
      habilitado = true,
      proxima_observacao_em = now(),
      atualizado_em = now()
  where plataforma = v_plataforma
    and coalesce(item_id, produto_catalogo) in (v_item, upper(v_item))
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', false, 'motivo', 'item_nao_esta_na_watchlist');
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'plataforma', v_plataforma, 'item', v_item);
end;
$$;

comment on function public.watchlist_vincular(text, text, text) is
  'Liga o link de afiliado a uma linha ja observada, em qualquer plataforma. Libera a publicacao e reagenda a leitura para agora.';

create or replace function public.watchlist_prontos_para_link()
returns table (
  plataforma text,
  item text,
  apelido text,
  categoria text,
  desconto numeric,
  pontuacao numeric,
  visto_em timestamptz,
  pagina text
)
language sql
security definer
set search_path to ''
as $$
  select i.plataforma,
         coalesce(i.produto_catalogo, i.item_id),
         i.apelido,
         i.categoria,
         i.pronto_desconto,
         i.pronto_pontuacao,
         i.pronto_em,
         -- So o ML tem URL de produto deduzivel a partir do id. Para as
         -- outras, devolver null e honesto; inventar padrao de URL daria link
         -- quebrado com cara de link bom.
         case when i.plataforma = 'mercado_livre' and i.produto_catalogo is not null
              then 'https://www.mercadolivre.com.br/p/' || i.produto_catalogo
              else null
         end
  from public.itens_ml i
  where i.url_afiliado is null
    and i.pronto_em is not null
    and i.habilitado
  order by i.pronto_desconto desc nulls last, i.pronto_em desc;
$$;

comment on function public.watchlist_prontos_para_link() is
  'Ja caiu de preco e so espera link, em qualquer plataforma. Gere link so para estes — e o inverso de gerar link no escuro.';

-- `ml_item_vincular` some do caminho de quem tem duas plataformas, mas fica:
-- esta no README e na memoria muscular. Passa a se limitar ao ML para nao
-- casar com linha de outra loja que tenha o mesmo id por acaso.
create or replace function public.ml_item_vincular(
  p_catalogo text,
  p_url_afiliado text
)
returns jsonb
language sql
security definer
set search_path to ''
as $$
  -- Devolve a chave 'catalogo', e nao 'item', porque e isso que quem ja usa
  -- esta funcao espera ler de volta.
  select case
           when (r ->> 'ok')::boolean
             then jsonb_build_object('ok', true, 'id', r -> 'id', 'catalogo', r -> 'item')
           else r
         end
  from public.watchlist_vincular(
         'mercado_livre',
         upper(btrim(coalesce(p_catalogo, ''))),
         p_url_afiliado
       ) as r;
$$;

-- ---------------------------------------------------------------------------
-- O pacote de compartilhamento para de perder oferta das outras lojas
--
-- Mudanca real: o link deixa de ser procurado so na watchlist. Plataforma que
-- devolve o link junto com a oferta grava em `ofertas.url_afiliado`, e ate
-- agora essa oferta sumia do resumo sem deixar rastro.
--
-- O join tambem passa a considerar a plataforma. Sem isso, `id_externo` de uma
-- loja poderia casar com `produto_catalogo` de outra e vestir a oferta com o
-- link errado — que e o unico erro aqui pior do que nao publicar.
-- ---------------------------------------------------------------------------

create or replace function public.para_compartilhar(p_horas integer default 24)
returns table (
  publicado_em timestamptz,
  produto text,
  preco numeric,
  desconto numeric,
  link text,
  whatsapp text,
  instagram text,
  para_o_x text
)
language sql
stable
security definer
set search_path to ''
as $$
  with recentes as (
    select p.publicado_em,
           o.preco_atual,
           o.preco_original,
           o.desconto_percentual,
           coalesce(o.url_afiliado, i.url_afiliado) as url_afiliado,
           case when char_length(o.titulo) > 70
                then left(o.titulo, 67) || '...'
                else o.titulo end as titulo_curto
    from public.publicacoes p
    join public.ofertas o on o.id = p.oferta_id
    join public.fontes f on f.id = o.fonte_id
    left join public.itens_ml i
      on i.plataforma = f.plataforma
     and coalesce(i.produto_catalogo, i.item_id) = o.id_externo
    where p.publicado_em > now() - make_interval(hours => greatest(1, coalesce(p_horas, 24)))
      and coalesce(o.url_afiliado, i.url_afiliado) is not null
  )
  select
    r.publicado_em,
    r.titulo_curto,
    r.preco_atual,
    r.desconto_percentual,
    r.url_afiliado,

    -- WhatsApp: *negrito* e _italico_ sao a marcacao dele. Link no fim, porque
    -- o app so gera a previa do ULTIMO link da mensagem.
    E'\U0001F525 ' || r.titulo_curto || E'\n\n' ||
    case when r.preco_original is not null and r.preco_original > r.preco_atual
         then 'De R$ ' || public.dinheiro(r.preco_original) || ' por *R$ '
              || public.dinheiro(r.preco_atual) || '*' || E'\n'
         else '*R$ ' || public.dinheiro(r.preco_atual) || '*' || E'\n'
    end ||
    case when r.desconto_percentual is not null
         then E'\U0001F4C9 ' || to_char(r.desconto_percentual, 'FM990') || '% abaixo do que já vimos' || E'\n'
         else '' end ||
    E'\n\U0001F449 ' || r.url_afiliado || E'\n\n_PUBLICIDADE • LINK DE AFILIADO_',

    -- Instagram, feed: link nao clica na legenda. Por isso o texto manda para
    -- a bio em vez de fingir que o link funciona ali. No story ele clica —
    -- veja `para_story()`.
    E'\U0001F525 ' || r.titulo_curto || E'\n\n' ||
    'R$ ' || public.dinheiro(r.preco_atual) ||
    case when r.desconto_percentual is not null
         then ' — ' || to_char(r.desconto_percentual, 'FM990') || '% abaixo do preço de costume'
         else '' end || E'\n\n' ||
    E'Link na bio \U0001F517\n\n' ||
    'PUBLICIDADE • LINK DE AFILIADO' || E'\n\n' ||
    '#promocao #oferta #desconto #achadinhos #baixou',

    -- X: 280 caracteres contando o link. Corta o titulo antes de estourar.
    left(
      E'\U0001F525 ' || left(r.titulo_curto, 90) || E'\n' ||
      'R$ ' || public.dinheiro(r.preco_atual) ||
      case when r.desconto_percentual is not null
           then ' (-' || to_char(r.desconto_percentual, 'FM990') || '%)'
           else '' end || E'\n' ||
      r.url_afiliado || E'\n#publicidade',
      280)
  from recentes r
  order by r.publicado_em desc;
$$;

create or replace function public.resumo_do_dia(p_quantas integer default 5)
returns text
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_linhas text := '';
  v_reg record;
  v_n integer := 0;
begin
  for v_reg in
    select o.titulo,
           o.preco_atual,
           o.desconto_percentual,
           coalesce(o.url_afiliado, i.url_afiliado) as url_afiliado
    from public.publicacoes p
    join public.ofertas o on o.id = p.oferta_id
    join public.fontes f on f.id = o.fonte_id
    left join public.itens_ml i
      on i.plataforma = f.plataforma
     and coalesce(i.produto_catalogo, i.item_id) = o.id_externo
    where p.publicado_em > now() - interval '24 hours'
      and coalesce(o.url_afiliado, i.url_afiliado) is not null
    order by o.desconto_percentual desc nulls last
    limit greatest(1, least(coalesce(p_quantas, 5), 10))
  loop
    v_n := v_n + 1;
    v_linhas := v_linhas
      || v_n || '. ' || case when char_length(v_reg.titulo) > 55
                             then left(v_reg.titulo, 52) || '...'
                             else v_reg.titulo end || E'\n'
      || '   R$ ' || public.dinheiro(v_reg.preco_atual)
      || case when v_reg.desconto_percentual is not null
              then ' (-' || to_char(v_reg.desconto_percentual, 'FM990') || '%)'
              else '' end || E'\n'
      || '   ' || v_reg.url_afiliado || E'\n\n';
  end loop;

  if v_n = 0 then
    return 'Nenhuma oferta publicada nas últimas 24 horas.';
  end if;

  return E'\U0001F4E2 *AS ' || v_n || E' MELHORES DE HOJE*\n\n'
      || v_linhas
      || E'Todo dia tem. Entra no canal: t.me/aixou_promocoes\n\n'
      || '_PUBLICIDADE • LINKS DE AFILIADO_';
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissoes
-- ---------------------------------------------------------------------------

revoke all on function public.watchlist_para_observar(text, smallint) from public, anon, authenticated;
revoke all on function public.watchlist_cadastrar(text, text, text, text, text, smallint) from public, anon;
revoke all on function public.watchlist_vincular(text, text, text) from public, anon;
revoke all on function public.watchlist_prontos_para_link() from public, anon;

grant execute on function public.watchlist_para_observar(text, smallint) to service_role;
grant execute on function public.watchlist_cadastrar(text, text, text, text, text, smallint) to service_role, authenticated;
grant execute on function public.watchlist_vincular(text, text, text) to service_role, authenticated;
grant execute on function public.watchlist_prontos_para_link() to service_role, authenticated;
