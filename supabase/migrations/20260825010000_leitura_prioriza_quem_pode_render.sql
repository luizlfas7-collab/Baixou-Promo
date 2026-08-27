-- Quem tem link de afiliado é lido primeiro
--
-- O coletor lê 120 itens por hora. Isso é o orçamento, e ele é fixo.
--
-- Produto sem link de afiliado não pode publicar — logo, não pode gerar
-- comissão. Cada leitura gasta nele é uma leitura a menos num produto que
-- PODE render. Com a descoberta automática criando itens sem link de hora em
-- hora, essa fatia só cresceria, e o efeito seria o oposto do pretendido:
-- watchlist maior rendendo menos.
--
-- A ordem passa a ser:
--   1. vencimento  (quem esperou mais)
--   2. TEM LINK    (quem pode render)
--   3. prioridade  (desempate)
--
-- Vencimento antes de link, de propósito: item sem link ainda precisa formar
-- histórico, senão no dia em que ganhar link não terá referência de preço e
-- levará dias até poder ser julgado. Ele é atendido — só perde a disputa
-- quando dois itens venceram na mesma hora.

drop function if exists public.ml_itens_para_observar(smallint);

create or replace function public.ml_itens_para_observar(p_limite smallint default 5)
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
  v_intervalo integer;
  v_limite smallint;
begin
  select coalesce(f.intervalo_coleta_segundos, 300) into v_intervalo
  from public.fontes f
  where f.slug = 'mercado_livre_api_oficial';

  v_limite := greatest(1, least(coalesce(p_limite, 5), 20));

  return query
  with vencidos as (
    select i.id
    from public.itens_ml i
    where i.habilitado
      and i.produto_catalogo is not null
      and i.proxima_observacao_em <= now()
    order by
      i.proxima_observacao_em,
      (i.url_afiliado is not null) desc,
      i.prioridade desc,
      i.id
    limit v_limite
    for update skip locked
  )
  update public.itens_ml i
    set proxima_observacao_em = now() + make_interval(secs => coalesce(v_intervalo, 300))
    from vencidos v
    where i.id = v.id
    returning i.id, i.item_id, i.url_afiliado, i.categoria, i.produto_catalogo;
end;
$$;

comment on function public.ml_itens_para_observar(smallint) is
  'Lote de itens vencidos. Quem tem link de afiliado ganha a disputa, porque so ele pode virar comissao.';

revoke all on function public.ml_itens_para_observar(smallint) from public, anon, authenticated;
grant execute on function public.ml_itens_para_observar(smallint) to service_role;

-- ---------------------------------------------------------------------------
-- Produto descoberto entra com prioridade baixa
--
-- Ele ainda nao provou nada e ainda nao rende. Fica atras do que foi escolhido
-- a mao ate ganhar link.
-- ---------------------------------------------------------------------------

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
          select 1 from public.itens_ml i where i.produto_catalogo = a.catalogo
        )
        limit v_espaco
      ),
      gravados as (
        insert into public.itens_ml
          (item_id, url_afiliado, categoria, apelido, produto_catalogo, prioridade, proxima_observacao_em)
        select null, null, 'Descoberta', null, n.catalogo, 50, now()
        from novos n
        on conflict (coalesce(item_id, produto_catalogo)) do nothing
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
-- A saude passa a mostrar quantos nao podem render
-- ---------------------------------------------------------------------------

create or replace function public.saude_da_coleta()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_ultima_rodada timestamptz;
  v_ultima_leitura timestamptz;
  v_minutos numeric;
  v_veredito text;
begin
  select max(e.iniciada_em) into v_ultima_rodada
  from public.execucoes e where e.tipo = 'coleta';

  select max(h.observado_em) into v_ultima_leitura from public.historico_precos h;

  v_minutos := extract(epoch from (now() - v_ultima_rodada)) / 60.0;

  v_veredito := case
    when v_ultima_rodada is null then 'sem_registro'
    when v_minutos > 20 then 'muda'
    when v_minutos > 10 then 'atrasada'
    else 'saudavel'
  end;

  return jsonb_build_object(
    'veredito', v_veredito,
    'ultima_rodada_em', v_ultima_rodada,
    'minutos_desde_a_rodada', round(v_minutos, 1),
    'ultima_leitura_em', v_ultima_leitura,
    'minutos_desde_a_leitura',
      round(extract(epoch from (now() - v_ultima_leitura)) / 60.0, 1),
    'rodadas_1h', (
      select count(*) from public.execucoes
      where tipo = 'coleta' and iniciada_em > now() - interval '1 hour'
    ),
    'falhas_1h', (
      select count(*) from public.execucoes
      where tipo = 'coleta' and situacao in ('falhou', 'parcial')
        and iniciada_em > now() - interval '1 hour'
    ),
    'penduradas', (
      select count(*) from public.execucoes
      where situacao = 'rodando' and iniciada_em < now() - interval '15 minutes'
    ),
    'leituras_1h', (
      select count(*) from public.historico_precos
      where observado_em > now() - interval '1 hour'
    ),
    'itens_na_watchlist', (select count(*) from public.itens_ml where habilitado),
    -- Quantos nao podem virar comissao. Se este numero cresce, a descoberta
    -- esta correndo mais rapido do que os links sao gerados.
    'itens_sem_link', (
      select count(*) from public.itens_ml where habilitado and url_afiliado is null
    )
  );
end;
$$;

revoke all on function public.saude_da_coleta() from public, anon;
grant execute on function public.saude_da_coleta() to service_role, authenticated;
