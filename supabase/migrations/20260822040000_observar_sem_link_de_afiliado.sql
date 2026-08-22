-- Observar deixa de exigir link de afiliado
--
-- Ate aqui a watchlist exigia o link no cadastro. Isso obrigava o operador a
-- gerar link ANTES de saber se o produto vale — no escuro, um por um — e por
-- isso a base de observacao ficou em 8 itens. Base pequena e o que mais limita
-- o resultado: o Baixou so anuncia queda que ele mesmo viu, entao quantas
-- oportunidades ele pega e funcao direta de quantos produtos ele vigia.
--
-- A ordem estava invertida. O link so faz falta na hora de publicar.
--
-- Agora: linha sem link observa, forma historico e pontua normalmente. Quando
-- pontua acima do corte, e carimbada como pronta para link em vez de ir para a
-- fila. O operador gera UM link para quem ja provou que caiu.
--
-- A garantia que sustenta isso: linha sem link nunca chega a publicacao. Sao
-- duas barreiras independentes — o coletor nem tenta enfileirar, e a validacao
-- de payload recusaria o post por URL fora da allowlist. Uma sozinha bastaria;
-- duas e porque publicar link errado e pior do que nao publicar.

-- ---------------------------------------------------------------------------
-- A coluna passa a aceitar nulo
-- ---------------------------------------------------------------------------

alter table public.itens_ml alter column url_afiliado drop not null;

alter table public.itens_ml drop constraint if exists itens_ml_url_afiliado_ck;

alter table public.itens_ml add constraint itens_ml_url_afiliado_ck
  check (
    url_afiliado is null
    or (char_length(btrim(url_afiliado)) between 8 and 500
        and btrim(url_afiliado) like 'https://%')
  );

-- ---------------------------------------------------------------------------
-- Carimbo de "pronto, faltando link"
-- ---------------------------------------------------------------------------

alter table public.itens_ml add column if not exists pronto_em timestamptz;
alter table public.itens_ml add column if not exists pronto_pontuacao numeric(5,2);
alter table public.itens_ml add column if not exists pronto_desconto numeric(5,2);

comment on column public.itens_ml.pronto_em is
  'Quando esta linha pontuou acima do corte sem ter link de afiliado. Preencher o link libera a publicacao.';

-- ---------------------------------------------------------------------------
-- Cadastro
--
-- p_url_afiliado continua na mesma posicao (nao da para dar default a ele sem
-- dar default ao catalogo, que e obrigatorio). Passa a aceitar null; quem nao
-- tem link chama ml_item_observar, abaixo.
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

  insert into public.itens_ml (item_id, url_afiliado, categoria, apelido, produto_catalogo, prioridade)
  values (
    v_item, v_link, coalesce(p_categoria, 'Ofertas gerais'),
    p_apelido, v_catalogo, greatest(least(coalesce(p_prioridade, 100), 1000), 0)
  )
  on conflict (coalesce(item_id, produto_catalogo)) do update
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

-- ---------------------------------------------------------------------------
-- Cadastrar so para observar
-- ---------------------------------------------------------------------------

create or replace function public.ml_item_observar(
  p_produto_catalogo text,
  p_categoria text default 'Ofertas gerais'::text,
  p_apelido text default null::text,
  p_item_id text default null::text,
  p_prioridade smallint default 100
)
returns bigint
language sql
security definer
set search_path to ''
as $$
  select public.ml_item_cadastrar(
    p_produto_catalogo, null, p_categoria, p_apelido, p_item_id, p_prioridade
  );
$$;

comment on function public.ml_item_observar(text, text, text, text, smallint) is
  'Poe um produto na watchlist so para observar preco. Sem link de afiliado nao publica — carimba como pronto e espera o link.';

-- ---------------------------------------------------------------------------
-- Carimbar como pronto
-- ---------------------------------------------------------------------------

create or replace function public.ml_item_pronto_para_link(
  p_id bigint,
  p_pontuacao numeric,
  p_desconto numeric
)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  update public.itens_ml
  set pronto_em = now(),
      pronto_pontuacao = round(p_pontuacao, 2),
      pronto_desconto = round(p_desconto, 2)
  where id = p_id
    and url_afiliado is null
    -- Mantem o melhor desconto ja visto em vez do ultimo: o pico e a
    -- informacao util para decidir se vale gerar link.
    and (pronto_desconto is null or p_desconto > pronto_desconto);
end;
$$;

-- ---------------------------------------------------------------------------
-- Vincular o link depois
-- ---------------------------------------------------------------------------

create or replace function public.ml_item_vincular(
  p_catalogo text,
  p_url_afiliado text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_catalogo text := nullif(upper(btrim(coalesce(p_catalogo, ''))), '');
  v_link text := nullif(btrim(coalesce(p_url_afiliado, '')), '');
  v_id bigint;
begin
  if v_catalogo is null or v_link is null then
    return jsonb_build_object('ok', false, 'motivo', 'catalogo_e_link_sao_obrigatorios');
  end if;

  update public.itens_ml
  set url_afiliado = v_link,
      pronto_em = null,
      pronto_pontuacao = null,
      pronto_desconto = null,
      habilitado = true,
      proxima_observacao_em = now()
  where produto_catalogo = v_catalogo
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', false, 'motivo', 'catalogo_nao_esta_na_watchlist');
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'catalogo', v_catalogo);
end;
$$;

-- ---------------------------------------------------------------------------
-- O que ja provou que vale um link
-- ---------------------------------------------------------------------------

create or replace function public.ml_prontos_para_link()
returns table (
  catalogo text,
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
  select i.produto_catalogo,
         i.apelido,
         i.categoria,
         i.pronto_desconto,
         i.pronto_pontuacao,
         i.pronto_em,
         'https://www.mercadolivre.com.br/p/' || i.produto_catalogo
  from public.itens_ml i
  where i.url_afiliado is null
    and i.pronto_em is not null
    and i.habilitado
  order by i.pronto_desconto desc nulls last, i.pronto_em desc;
$$;

comment on function public.ml_prontos_para_link() is
  'Produtos que ja cairam de preco e so esperam link de afiliado para publicar. Gere link so para estes.';

-- ---------------------------------------------------------------------------
-- Permissoes
-- ---------------------------------------------------------------------------

revoke all on function public.ml_item_observar(text, text, text, text, smallint) from public, anon;
revoke all on function public.ml_item_pronto_para_link(bigint, numeric, numeric) from public, anon, authenticated;
revoke all on function public.ml_item_vincular(text, text) from public, anon;
revoke all on function public.ml_prontos_para_link() from public, anon;

grant execute on function public.ml_item_observar(text, text, text, text, smallint) to service_role, authenticated;
grant execute on function public.ml_item_pronto_para_link(bigint, numeric, numeric) to service_role;
grant execute on function public.ml_item_vincular(text, text) to service_role, authenticated;
grant execute on function public.ml_prontos_para_link() to service_role, authenticated;
