-- O /items/{id} de anuncio de terceiro responde 403 para este tipo de
-- aplicacao, com ou sem escopo. O caminho que funciona e
-- /products/{catalogo}/items, que devolve todos os anuncios que disputam
-- aquele produto de catalogo, com preco e preco original.
--
-- Por isso a watchlist passa a guardar tambem o id de catalogo: e ele que
-- abre a porta, e o item_id serve para escolher a linha certa na resposta.
alter table public.itens_ml
  add column if not exists produto_catalogo text;

alter table public.itens_ml
  drop constraint if exists itens_ml_catalogo_ck;

alter table public.itens_ml
  add constraint itens_ml_catalogo_ck check (
    produto_catalogo is null or produto_catalogo ~ '^MLB[0-9]{6,20}$'
  );

comment on column public.itens_ml.produto_catalogo is
  'Id do produto de catalogo. Sem ele nao ha como ler preco: /items esta fechado.';

-- Item sem catalogo nao tem como ser coletado; sai da fila de observacao.
drop index if exists itens_ml_a_observar_idx;
create index itens_ml_a_observar_idx
  on public.itens_ml (proxima_observacao_em, id)
  where habilitado and produto_catalogo is not null;

drop function if exists public.ml_item_cadastrar(text, text, text, text);
drop function if exists public.ml_itens_para_observar(smallint);

create function public.ml_item_cadastrar(
  p_item_id text,
  p_url_afiliado text,
  p_categoria text default 'Ofertas gerais',
  p_apelido text default null,
  p_produto_catalogo text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  insert into public.itens_ml (item_id, url_afiliado, categoria, apelido, produto_catalogo)
  values (
    upper(btrim(p_item_id)),
    btrim(p_url_afiliado),
    coalesce(p_categoria, 'Ofertas gerais'),
    p_apelido,
    nullif(upper(btrim(coalesce(p_produto_catalogo, ''))), '')
  )
  on conflict (item_id) do update
    set url_afiliado = excluded.url_afiliado,
        categoria = excluded.categoria,
        apelido = coalesce(excluded.apelido, public.itens_ml.apelido),
        produto_catalogo = coalesce(excluded.produto_catalogo, public.itens_ml.produto_catalogo),
        habilitado = true,
        falhas_seguidas = 0,
        ultimo_erro = null,
        proxima_observacao_em = now()
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.ml_item_cadastrar(text, text, text, text, text) from anon, authenticated, public;
grant execute on function public.ml_item_cadastrar(text, text, text, text, text) to service_role;

create function public.ml_itens_para_observar(p_limite smallint default 5)
returns table (id bigint, item_id text, url_afiliado text, categoria text, produto_catalogo text)
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
      and i.produto_catalogo is not null
      and i.proxima_observacao_em <= now()
    order by i.proxima_observacao_em, i.id
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

revoke execute on function public.ml_itens_para_observar(smallint) from anon, authenticated, public;
grant execute on function public.ml_itens_para_observar(smallint) to service_role;
