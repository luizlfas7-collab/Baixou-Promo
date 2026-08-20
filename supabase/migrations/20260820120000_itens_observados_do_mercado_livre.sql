-- ---------------------------------------------------------------------------
-- itens_ml: a lista do que observar no Mercado Livre.
--
-- O programa de afiliados do ML nao expoe API para gerar link: cada par
-- MLB + meli.la e criado a mao nas ferramentas oficiais e cadastrado aqui.
-- Por isso o link e obrigatorio: item sem link de afiliado nao rende nada e
-- nao deveria ocupar rodada de coleta.
--
-- A restricao do formato do link e a mesma allowlist do publicador
-- (_compartilhado/afiliados.ts). Duas barreiras dizendo a mesma coisa: um
-- link torto morre no cadastro, e nao tres etapas adiante.
-- ---------------------------------------------------------------------------
create table public.itens_ml (
  id bigint primary key generated always as identity,
  item_id text not null unique
    constraint itens_ml_item_ck check (item_id ~ '^MLB[0-9]{6,20}$'),
  url_afiliado text not null
    constraint itens_ml_afiliado_ck check (url_afiliado ~ '^https://meli\.la/[A-Za-z0-9]{4,32}$'),
  categoria text not null default 'Ofertas gerais'
    constraint itens_ml_categoria_ck check (char_length(categoria) between 2 and 80),
  apelido text
    constraint itens_ml_apelido_ck check (apelido is null or char_length(apelido) <= 160),
  habilitado boolean not null default true,
  observado_em timestamptz,
  proxima_observacao_em timestamptz not null default now(),
  falhas_seguidas smallint not null default 0
    constraint itens_ml_falhas_ck check (falhas_seguidas >= 0),
  ultimo_erro text
    constraint itens_ml_erro_ck check (ultimo_erro is null or char_length(ultimo_erro) <= 500),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

comment on table public.itens_ml is
  'Watchlist do Mercado Livre. Cada linha e um par MLB + link de afiliado verificado.';

create index itens_ml_a_observar_idx
  on public.itens_ml (proxima_observacao_em, id)
  where habilitado;

alter table public.itens_ml enable row level security;

create policy "operador ativo le itens do ml"
  on public.itens_ml for select to authenticated
  using (public.eh_operador_ativo());

create trigger ao_atualizar_item_ml
  before update on public.itens_ml
  for each row execute function public.toca_atualizado_em();

create trigger auditar after insert or update or delete on public.itens_ml
  for each row execute function public.grava_auditoria();

-- ---------------------------------------------------------------------------
-- ml_item_cadastrar: entrada unica da watchlist. Recadastrar o mesmo item
-- atualiza o link em vez de estourar, porque link de afiliado e refeito com
-- alguma frequencia.
-- ---------------------------------------------------------------------------
create function public.ml_item_cadastrar(
  p_item_id text,
  p_url_afiliado text,
  p_categoria text default 'Ofertas gerais',
  p_apelido text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  insert into public.itens_ml (item_id, url_afiliado, categoria, apelido)
  values (upper(btrim(p_item_id)), btrim(p_url_afiliado), coalesce(p_categoria, 'Ofertas gerais'), p_apelido)
  on conflict (item_id) do update
    set url_afiliado = excluded.url_afiliado,
        categoria = excluded.categoria,
        apelido = coalesce(excluded.apelido, public.itens_ml.apelido),
        habilitado = true,
        falhas_seguidas = 0,
        ultimo_erro = null,
        proxima_observacao_em = now()
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.ml_item_cadastrar(text, text, text, text) from anon, authenticated, public;
grant execute on function public.ml_item_cadastrar(text, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- ml_itens_para_observar: entrega o lote vencido e ja reagenda, na mesma
-- transacao. Reagendar aqui, e nao depois de coletar, e o que impede um
-- coletor que morreu no meio de deixar o item preso para sempre.
-- ---------------------------------------------------------------------------
create function public.ml_itens_para_observar(p_limite smallint default 5)
returns table (id bigint, item_id text, url_afiliado text, categoria text)
language plpgsql
security definer
set search_path = ''
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
      and i.proxima_observacao_em <= now()
    order by i.proxima_observacao_em, i.id
    limit v_limite
    for update skip locked
  )
  update public.itens_ml i
    set proxima_observacao_em = now() + make_interval(secs => coalesce(v_intervalo, 300))
    from vencidos v
    where i.id = v.id
    returning i.id, i.item_id, i.url_afiliado, i.categoria;
end;
$$;

revoke execute on function public.ml_itens_para_observar(smallint) from anon, authenticated, public;
grant execute on function public.ml_itens_para_observar(smallint) to service_role;

-- ---------------------------------------------------------------------------
-- ml_item_falhou: guarda o motivo e vai afastando o item. Nove falhas
-- seguidas desabilitam: item que sumiu do catalogo nao pode consumir rodada
-- de coleta para sempre.
-- ---------------------------------------------------------------------------
create function public.ml_item_falhou(p_id bigint, p_motivo text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.itens_ml
    set falhas_seguidas = falhas_seguidas + 1,
        ultimo_erro = left(p_motivo, 500),
        habilitado = case when falhas_seguidas + 1 >= 9 then false else habilitado end,
        proxima_observacao_em = now() + make_interval(
          secs => least(300 * power(2, least(falhas_seguidas, 6))::integer, 86400)
        )
    where id = p_id;
end;
$$;

revoke execute on function public.ml_item_falhou(bigint, text) from anon, authenticated, public;
grant execute on function public.ml_item_falhou(bigint, text) to service_role;

-- ---------------------------------------------------------------------------
-- ml_item_observado: zera o contador de falhas depois de uma leitura boa.
-- ---------------------------------------------------------------------------
create function public.ml_item_observado(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.itens_ml
    set observado_em = now(),
        falhas_seguidas = 0,
        ultimo_erro = null
    where id = p_id;
end;
$$;

revoke execute on function public.ml_item_observado(bigint) from anon, authenticated, public;
grant execute on function public.ml_item_observado(bigint) to service_role;
