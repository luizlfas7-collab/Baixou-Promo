-- Descoberta automática de produtos
--
-- A watchlist crescia só à mão. Como o Baixou só anuncia queda que ele mesmo
-- observou, o número de produtos vigiados é o que limita quantas oportunidades
-- ele pega — e enchê-la a mão nao escala.
--
-- A vitrine publica de ofertas do ML responde 200 ao pg_net, com o id de
-- catalogo no HTML. Entao o proprio banco consegue colher, sem navegador e sem
-- API (a busca oficial responde 403).
--
-- Duas travas de propósito:
--
-- 1. TETO DE WATCHLIST. O coletor le 10 itens a cada 5 min, ou 120 por hora.
--    Com 200 itens a revisita fica em ~1h40. Passar disso transforma revisita
--    em horas e queda relampago passa batido — crescer a lista sem crescer a
--    vazao PIORA o resultado.
--
-- 2. NUNCA REABILITA. A insercao e direta, com `on conflict do nothing`, e nao
--    passa por ml_item_cadastrar. Aquela funcao faz `habilitado = true` no
--    conflito, o que ressuscitaria os produtos recusados pelo Programa de
--    Afiliados toda vez que aparecessem na vitrine de novo.
--
-- Produto descoberto entra SEM link de afiliado: observa e pontua, mas nao
-- publica. Só vira post depois que alguem gerar o link.

create table if not exists public.descobertas_pendentes (
  id bigint primary key generated always as identity,
  pedido_id bigint not null unique,
  url text not null,
  pedida_em timestamptz not null default now(),
  processada_em timestamptz,
  encontrados integer,
  inseridos integer
);

comment on table public.descobertas_pendentes is
  'Requisicoes de descoberta em voo. O pg_net e assincrono: uma rodada dispara, a seguinte le a resposta.';

create index if not exists descobertas_pendentes_abertas_idx
  on public.descobertas_pendentes (pedida_em)
  where processada_em is null;

-- ---------------------------------------------------------------------------
-- Teto da watchlist, num lugar so
-- ---------------------------------------------------------------------------

create or replace function public.watchlist_teto()
returns integer
language sql
immutable
set search_path to ''
as $$ select 200 $$;

comment on function public.watchlist_teto() is
  'Maximo de itens habilitados. Amarrado a vazao do coletor: 120 leituras/hora dao revisita de ~1h40 em 200 itens.';

-- ---------------------------------------------------------------------------
-- Passo 1: pedir as paginas
-- ---------------------------------------------------------------------------

create or replace function public.descoberta_disparar(p_paginas integer default 3)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_ativos integer;
  v_pedido bigint;
  v_url text;
  v_total integer := 0;
begin
  select count(*) into v_ativos from public.itens_ml where habilitado;

  -- Nao pede pagina se nao ha espaco para o resultado.
  if v_ativos >= public.watchlist_teto() then
    return 0;
  end if;

  for i in 1..greatest(1, least(coalesce(p_paginas, 3), 8)) loop
    v_url := 'https://www.mercadolivre.com.br/ofertas?page=' || i;

    select net.http_get(
      url := v_url,
      headers := jsonb_build_object(
        'User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36',
        'Accept', 'text/html'
      )
    ) into v_pedido;

    insert into public.descobertas_pendentes (pedido_id, url)
    values (v_pedido, v_url)
    on conflict (pedido_id) do nothing;

    v_total := v_total + 1;
  end loop;

  return v_total;
end;
$$;

-- ---------------------------------------------------------------------------
-- Passo 2: ler as respostas e cadastrar
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

    -- Resposta ainda nao chegou: deixa para a proxima rodada. Mas pedido de
    -- mais de 1 hora e resposta perdida (o pg_net limpa a tabela), entao
    -- encerra em vez de ficar pendurado para sempre.
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
        select null, null, 'Descoberta', null, n.catalogo, 150, now()
        from novos n
        -- Direto, sem ml_item_cadastrar: aquela funcao reabilita no conflito e
        -- ressuscitaria produto recusado pelo Programa de Afiliados.
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
    'teto', public.watchlist_teto()
  );
end;
$$;

comment on function public.descoberta_coletar(integer) is
  'Le as respostas em voo, extrai ids de catalogo e cadastra como observacao pura (sem link de afiliado).';

-- ---------------------------------------------------------------------------
-- Uma rodada inteira: colhe o que chegou, pede mais
-- ---------------------------------------------------------------------------

create or replace function public.rodar_descoberta()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_colheita jsonb;
  v_pedidos integer;
begin
  -- Colher primeiro: as respostas em voo sao da rodada anterior.
  v_colheita := public.descoberta_coletar();
  v_pedidos := public.descoberta_disparar();

  -- Faxina: pendencia antiga so ocupa espaco.
  delete from public.descobertas_pendentes
  where processada_em is not null and processada_em < now() - interval '7 days';

  return v_colheita || jsonb_build_object('paginas_pedidas', v_pedidos);
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissoes
-- ---------------------------------------------------------------------------

alter table public.descobertas_pendentes enable row level security;

revoke all on function public.descoberta_disparar(integer) from public, anon, authenticated;
revoke all on function public.descoberta_coletar(integer) from public, anon, authenticated;
revoke all on function public.rodar_descoberta() from public, anon;

grant execute on function public.descoberta_disparar(integer) to service_role;
grant execute on function public.descoberta_coletar(integer) to service_role;
grant execute on function public.rodar_descoberta() to service_role, authenticated;
grant execute on function public.watchlist_teto() to service_role, authenticated;
