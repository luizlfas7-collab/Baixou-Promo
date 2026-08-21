-- Nem todo link de afiliado aponta para um anuncio especifico. Quando ele
-- leva a pagina do catalogo, quem clica compra de quem estiver ganhando a
-- vitrine naquele momento — e e esse preco que o leitor vai ver.
--
-- Entao a watchlist passa a aceitar linha sem item_id: nesse modo o coletor
-- segue o vencedor, e nao um vendedor fixo.
alter table public.itens_ml alter column item_id drop not null;

alter table public.itens_ml drop constraint if exists itens_ml_item_id_key;

-- Identidade da linha: o anuncio quando existe, senao o catalogo.
create unique index if not exists itens_ml_identidade_idx
  on public.itens_ml (coalesce(item_id, produto_catalogo));

alter table public.itens_ml
  drop constraint if exists itens_ml_precisa_de_alvo_ck;

alter table public.itens_ml
  add constraint itens_ml_precisa_de_alvo_ck
    check (produto_catalogo is not null);

drop function if exists public.ml_item_cadastrar(text, text, text, text, text);

create function public.ml_item_cadastrar(
  p_produto_catalogo text,
  p_url_afiliado text,
  p_categoria text default 'Ofertas gerais',
  p_apelido text default null,
  p_item_id text default null
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

  insert into public.itens_ml (item_id, url_afiliado, categoria, apelido, produto_catalogo)
  values (v_item, btrim(p_url_afiliado), coalesce(p_categoria, 'Ofertas gerais'), p_apelido, v_catalogo)
  on conflict (coalesce(item_id, produto_catalogo)) do update
    set url_afiliado = excluded.url_afiliado,
        categoria = excluded.categoria,
        apelido = coalesce(excluded.apelido, public.itens_ml.apelido),
        produto_catalogo = excluded.produto_catalogo,
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
