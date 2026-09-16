-- Comissao por produto, e o ganho esperado que ela permite calcular
--
-- O painel de afiliado do ML informa a taxa de comissao de cada produto (5%,
-- 12%, 24%...). Ate agora o Baixou tratava todos igual, cego para quanto cada
-- venda rende.
--
-- ATENCAO A UMA ARMADILHA: porcentagem sozinha engana. Um produto de 24% a
-- R$ 176 rende R$ 42,24; um de 5% a R$ 899 rende R$ 44,95 — o de porcentagem
-- MENOR paga mais. O que ordena e `preco x comissao`, nunca a taxa isolada.
--
-- ONDE A COMISSAO ENTRA, E ONDE NAO ENTRA
--
-- Entra: na ordem de LEITURA e na ordem da FILA. Entre duas ofertas
-- igualmente boas, atender primeiro a que rende mais e simplesmente bom senso.
--
-- NAO entra: na PONTUACAO. A nota responde "isto e um bom negocio para quem
-- le". Misturar quanto eu ganho corromperia essa resposta — passaria a
-- publicar oferta pior porque paga melhor, e o leitor sentiria antes de saber
-- explicar. O interesse do dono e o do leitor so continuam alinhados enquanto
-- o dinheiro decide a ORDEM e nunca o CORTE.

alter table public.itens_ml add column if not exists comissao_pct numeric(5,2);

alter table public.itens_ml drop constraint if exists itens_ml_comissao_ck;
alter table public.itens_ml add constraint itens_ml_comissao_ck
  check (comissao_pct is null or (comissao_pct >= 0 and comissao_pct <= 100));

comment on column public.itens_ml.comissao_pct is
  'Taxa de comissao informada pelo painel de afiliado. Ordena leitura e fila; nunca entra na pontuacao.';

-- ---------------------------------------------------------------------------
-- Registrar a comissao
-- ---------------------------------------------------------------------------

create or replace function public.ml_item_comissao(p_catalogo text, p_pct numeric)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_catalogo text := nullif(upper(btrim(coalesce(p_catalogo, ''))), '');
  v_id bigint;
begin
  if v_catalogo is null then
    return jsonb_build_object('ok', false, 'motivo', 'catalogo_obrigatorio');
  end if;

  update public.itens_ml
  set comissao_pct = p_pct
  where produto_catalogo = v_catalogo
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', false, 'motivo', 'nao_esta_na_watchlist');
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'comissao', p_pct);
end;
$$;

-- ---------------------------------------------------------------------------
-- Ganho esperado: o numero que realmente ordena
-- ---------------------------------------------------------------------------

create or replace function public.ml_ganho_esperado(p_catalogo text)
returns numeric
language sql
stable
security definer
set search_path to ''
as $$
  select round(o.preco_atual * (i.comissao_pct / 100.0), 2)
  from public.itens_ml i
  join public.ofertas o on o.id_externo = i.produto_catalogo
  where i.produto_catalogo = p_catalogo
    and i.comissao_pct is not null
    and o.preco_atual is not null
  limit 1;
$$;

comment on function public.ml_ganho_esperado(text) is
  'Comissao em reais: preco x taxa. E o que ordena — porcentagem isolada engana.';

-- ---------------------------------------------------------------------------
-- A leitura passa a preferir quem rende mais
--
-- A ordem fica: vencimento, tem link, GANHO ESPERADO, prioridade.
--
-- Vencimento continua primeiro para ninguem morrer de fome na fila; ter link
-- vem antes porque sem ele nao ha comissao nenhuma; e so entao o dinheiro
-- desempata.
-- ---------------------------------------------------------------------------

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
    left join public.ofertas o on o.id_externo = i.produto_catalogo
    where i.habilitado
      and i.produto_catalogo is not null
      and i.proxima_observacao_em <= now()
    order by
      i.proxima_observacao_em,
      (i.url_afiliado is not null) desc,
      -- Ganho em reais, nao a taxa: 5% de R$ 899 paga mais que 24% de R$ 176.
      coalesce(o.preco_atual * (i.comissao_pct / 100.0), 0) desc,
      i.prioridade desc,
      i.id
    limit v_limite
    for update of i skip locked
  )
  update public.itens_ml i
    set proxima_observacao_em = now() + make_interval(secs => coalesce(v_intervalo, 300))
    from vencidos v
    where i.id = v.id
    returning i.id, i.item_id, i.url_afiliado, i.categoria, i.produto_catalogo;
end;
$$;

comment on function public.ml_itens_para_observar(smallint) is
  'Lote de itens vencidos. Ordem: vencimento, tem link, ganho esperado, prioridade.';

revoke all on function public.ml_itens_para_observar(smallint) from public, anon, authenticated;
revoke all on function public.ml_item_comissao(text, numeric) from public, anon;
revoke all on function public.ml_ganho_esperado(text) from public, anon;

grant execute on function public.ml_itens_para_observar(smallint) to service_role;
grant execute on function public.ml_item_comissao(text, numeric) to service_role, authenticated;
grant execute on function public.ml_ganho_esperado(text) to service_role, authenticated;

-- ---------------------------------------------------------------------------
-- A lista de "pronto para link" mostra quanto cada um renderia
-- ---------------------------------------------------------------------------

-- Duas colunas novas mudam o tipo de retorno, e `create or replace` nao muda
-- tipo de retorno — precisa derrubar antes. Sem este drop a migration falha em
-- banco novo, e com ela para a fila inteira de migrations daqui para a frente.
drop function if exists public.ml_prontos_para_link();

create or replace function public.ml_prontos_para_link()
returns table (
  catalogo text,
  apelido text,
  categoria text,
  desconto numeric,
  pontuacao numeric,
  comissao_pct numeric,
  ganho_estimado numeric,
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
         i.comissao_pct,
         public.ml_ganho_esperado(i.produto_catalogo),
         i.pronto_em,
         'https://www.mercadolivre.com.br/p/' || i.produto_catalogo
  from public.itens_ml i
  where i.url_afiliado is null
    and i.pronto_em is not null
    and i.habilitado
  order by public.ml_ganho_esperado(i.produto_catalogo) desc nulls last,
           i.pronto_desconto desc nulls last;
$$;

revoke all on function public.ml_prontos_para_link() from public, anon;
grant execute on function public.ml_prontos_para_link() to service_role, authenticated;
