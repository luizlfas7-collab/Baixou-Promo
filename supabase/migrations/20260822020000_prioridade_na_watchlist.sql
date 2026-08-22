-- Com a lista pequena, ordem por vencimento basta. Quando ela crescer, uns
-- produtos merecem ser olhados antes dos outros — os que variam mais, os de
-- ticket alto, os de campanha. Prioridade maior sai primeiro dentro do lote.
alter table public.itens_ml
  add column if not exists prioridade smallint not null default 100;

alter table public.itens_ml drop constraint if exists itens_ml_prioridade_ck;
alter table public.itens_ml
  add constraint itens_ml_prioridade_ck check (prioridade between 0 and 1000);

comment on column public.itens_ml.prioridade is
  'Maior sai primeiro dentro do lote vencido. Padrao 100.';

drop index if exists itens_ml_a_observar_idx;
create index itens_ml_a_observar_idx
  on public.itens_ml (proxima_observacao_em, prioridade desc, id)
  where habilitado and produto_catalogo is not null;

create or replace function public.ml_itens_para_observar(p_limite smallint default 5)
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
    -- Vencimento antes de prioridade: prioridade desempata, nao atropela.
    -- Se atropelasse, item de prioridade baixa nunca seria observado.
    order by i.proxima_observacao_em, i.prioridade desc, i.id
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

drop function if exists public.ml_item_cadastrar(text, text, text, text, text);

create function public.ml_item_cadastrar(
  p_produto_catalogo text,
  p_url_afiliado text,
  p_categoria text default 'Ofertas gerais',
  p_apelido text default null,
  p_item_id text default null,
  p_prioridade smallint default 100
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_catalogo text := nullif(upper(btrim(coalesce(p_produto_catalogo, ''))), '');
  v_item text := nullif(upper(btrim(coalesce(p_item_id, ''))), '');
  v_id bigint;
begin
  if v_catalogo is null then
    raise exception 'Produto de catalogo e obrigatorio: sem ele nao ha como ler preco'
      using errcode = '22023';
  end if;

  insert into public.itens_ml (item_id, url_afiliado, categoria, apelido, produto_catalogo, prioridade)
  values (
    v_item, btrim(p_url_afiliado), coalesce(p_categoria, 'Ofertas gerais'),
    p_apelido, v_catalogo, greatest(least(coalesce(p_prioridade, 100), 1000), 0)
  )
  on conflict (coalesce(item_id, produto_catalogo)) do update
    set url_afiliado = excluded.url_afiliado,
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

revoke execute on function public.ml_item_cadastrar(text, text, text, text, text, smallint) from anon, authenticated, public;
grant execute on function public.ml_item_cadastrar(text, text, text, text, text, smallint) to service_role;

-- Erro do canal errado, de 19/08, ja corrigido pela migration
-- corrige_o_canal_de_destino. Fica como historico, nao como pendencia.
update public.erros
   set resolvido_em = now()
 where codigo = 'telegram_400'
   and mensagem like '%chat not found%'
   and resolvido_em is null;
