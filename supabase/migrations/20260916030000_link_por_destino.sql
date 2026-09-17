-- Um link por destino: saber de onde veio o clique sem mascarar nada
--
-- O PROBLEMA
--
-- Hoje o Baixou nao sabe se o Instagram traz clique. Tem um link de afiliado
-- por produto, usado em todo lugar, e o painel do afiliado soma tudo junto.
-- Sem separar origem, "o Instagram funciona?" nao tem resposta — e a nota do
-- Social Score fica cega para desempenho justamente por isso.
--
-- O CAMINHO QUE NAO VAMOS SEGUIR
--
-- A saida obvia seria um redirect proprio: baixou.com/oferta/123 conta o
-- clique e manda para o afiliado. Nao vamos fazer isso, por dois motivos que
-- se reforcam:
--
--   1. E exatamente o padrao que `_compartilhado/afiliados.ts` existe para
--      recusar. `ehLinkDeAfiliado()` so aceita encurtador oficial, com query
--      vazia, e `temUrlAninhada()` rejeita URL dentro de URL. Mascarar link de
--      afiliado atras de dominio proprio e o caso classico.
--
--   2. Programa de afiliado costuma tratar isso como cloaking, e este projeto
--      ja tomou um aviso do Mercado Livre. Ganhar metrica arriscando a conta
--      que paga as contas e um mau negocio.
--
-- O CAMINHO QUE OS DOIS PROGRAMAS JA OFERECEM
--
-- Marcar a origem na HORA DE GERAR o link, e nao depois, na URL:
--
--   Shopee  — `generateShortLink` aceita `subIds` (ate 5). Os sub-ids entram
--             DENTRO do shortlink s.shopee.com.br, nao como query. Passa na
--             allowlist sem exigir nenhuma excecao.
--   ML      — o Portal do Afiliado cria links com etiqueta, e reporta metrica
--             por etiqueta.
--
-- Nos dois casos o link continua sendo um encurtador oficial. Nada muda para
-- quem clica, e nada muda na allowlist.
--
-- O QUE ESTA TABELA FAZ
--
-- Guarda um link OPCIONAL por destino. Quando existe, ele e usado; quando nao
-- existe, cai no link de sempre. Ou seja: enquanto ninguem gerar link
-- etiquetado, absolutamente nada muda de comportamento.
--
-- O CUSTO, DITO NA CARA
--
-- Na Shopee sai de graca: o coletor pede o shortlink com subIds e pronto.
-- No ML custa um link a mais gerado a mao por produto e por destino — e gerar
-- link a mao e justamente o gargalo que travou a watchlist em 8 itens. Por
-- isso a tabela e opcional e comeca vazia: vale a pena etiquetar os poucos
-- produtos que forem virar post de Instagram, nao a watchlist inteira.

create table if not exists public.links_por_destino (
  id bigint primary key generated always as identity,
  item_id bigint not null references public.itens_ml (id) on delete cascade,

  destino text not null
    constraint links_destino_ck check (destino in (
      'telegram', 'instagram_story', 'instagram_feed', 'whatsapp', 'x'
    )),

  url_afiliado text not null
    constraint links_url_ck check (
      char_length(btrim(url_afiliado)) between 8 and 500
      and btrim(url_afiliado) like 'https://%'
    ),

  -- A etiqueta (ML) ou os sub-ids (Shopee) usados ao gerar. Guardados para o
  -- numero do painel do afiliado poder ser cruzado com a linha daqui; sem
  -- isso, descobrir qual etiqueta era qual vira arqueologia.
  etiqueta text
    constraint links_etiqueta_ck check (
      etiqueta is null or char_length(btrim(etiqueta)) between 1 and 120
    ),

  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),

  constraint links_item_destino_uk unique (item_id, destino)
);

comment on table public.links_por_destino is
  'Link de afiliado etiquetado por destino. Opcional: sem linha aqui, vale o link padrao do item.';

comment on column public.links_por_destino.etiqueta is
  'Etiqueta do Portal do Afiliado (ML) ou sub-ids (Shopee). E o que liga o numero do painel a esta linha.';

create index if not exists links_por_destino_item_idx
  on public.links_por_destino (item_id, destino);

alter table public.links_por_destino enable row level security;

create policy "operador ativo le links por destino"
  on public.links_por_destino for select to authenticated
  using (public.eh_operador_ativo());

-- ---------------------------------------------------------------------------
-- Quem resolve o link
--
-- Ordem: etiquetado para o destino > link da oferta > link da watchlist.
--
-- O link da oferta vem antes do da watchlist porque plataforma que devolve
-- link junto com o produto (Shopee) ja entrega o mais especifico que existe.
-- ---------------------------------------------------------------------------

create or replace function public.link_para(p_oferta_id bigint, p_destino text)
returns text
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(
    (select l.url_afiliado
     from public.links_por_destino l
     join public.itens_ml i on i.id = l.item_id
     join public.ofertas o on o.id = p_oferta_id
     join public.fontes f on f.id = o.fonte_id
     where l.destino = p_destino
       and i.plataforma = f.plataforma
       and coalesce(i.produto_catalogo, i.item_id) = o.id_externo
     limit 1),
    (select o.url_afiliado from public.ofertas o where o.id = p_oferta_id),
    (select i.url_afiliado
     from public.itens_ml i
     join public.ofertas o on o.id = p_oferta_id
     join public.fontes f on f.id = o.fonte_id
     where i.plataforma = f.plataforma
       and coalesce(i.produto_catalogo, i.item_id) = o.id_externo
     limit 1)
  );
$$;

comment on function public.link_para(bigint, text) is
  'O link daquela oferta para aquele destino. Cai no link padrao quando nao ha etiquetado — por isso adotar isto nao muda nada ate alguem etiquetar.';

-- ---------------------------------------------------------------------------
-- Cadastrar o link etiquetado
-- ---------------------------------------------------------------------------

create or replace function public.link_destino_definir(
  p_plataforma text,
  p_id_do_item text,
  p_destino text,
  p_url_afiliado text,
  p_etiqueta text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_plataforma text := lower(nullif(btrim(coalesce(p_plataforma, '')), ''));
  v_item text := nullif(btrim(coalesce(p_id_do_item, '')), '');
  v_url text := nullif(btrim(coalesce(p_url_afiliado, '')), '');
  v_item_id bigint;
  v_id bigint;
begin
  if v_plataforma is null or v_item is null or v_url is null or p_destino is null then
    return jsonb_build_object('ok', false, 'motivo', 'plataforma_item_destino_e_url_sao_obrigatorios');
  end if;

  select i.id into v_item_id
  from public.itens_ml i
  where i.plataforma = v_plataforma
    and coalesce(i.item_id, i.produto_catalogo) in (v_item, upper(v_item));

  if v_item_id is null then
    return jsonb_build_object('ok', false, 'motivo', 'item_nao_esta_na_watchlist');
  end if;

  insert into public.links_por_destino (item_id, destino, url_afiliado, etiqueta)
  values (v_item_id, p_destino, v_url, nullif(btrim(coalesce(p_etiqueta, '')), ''))
  on conflict (item_id, destino) do update
    set url_afiliado = excluded.url_afiliado,
        etiqueta = coalesce(excluded.etiqueta, public.links_por_destino.etiqueta),
        atualizado_em = now()
  returning id into v_id;

  return jsonb_build_object(
    'ok', true, 'id', v_id, 'plataforma', v_plataforma,
    'item', v_item, 'destino', p_destino
  );
end;
$$;

comment on function public.link_destino_definir(text, text, text, text, text) is
  'Liga um link etiquetado a um destino. Gere so para os produtos que forem virar post — etiquetar a watchlist inteira e trabalho jogado fora.';

-- ---------------------------------------------------------------------------
-- O story passa a preferir o link etiquetado
--
-- Mesmo retorno; muda so a resolucao do link. Sem linha etiquetada, devolve
-- exatamente o que devolvia antes.
-- ---------------------------------------------------------------------------

create or replace function public.para_story(p_horas integer default 24)
returns table (
  publicado_em timestamptz,
  produto text,
  foto text,
  chamada text,
  link_do_sticker text,
  preco_no_post numeric,
  preco_agora numeric,
  o_preco text
)
language sql
stable
security definer
set search_path to ''
as $$
  with recentes as (
    select p.publicado_em,
           o.id as oferta_id,
           o.preco_atual,
           o.preco_original,
           o.desconto_percentual,
           o.url_imagem,
           o.disponivel,
           public.link_para(o.id, 'instagram_story') as url_afiliado,
           case when char_length(o.titulo) > 55
                then left(o.titulo, 52) || '...'
                else o.titulo end as titulo_curto,
           (select h.preco
            from public.historico_precos h
            where h.oferta_id = o.id
              and h.observado_em <= p.publicado_em
            order by h.observado_em desc
            limit 1) as preco_publicado
    from public.publicacoes p
    join public.ofertas o on o.id = p.oferta_id
    where p.publicado_em > now() - make_interval(hours => greatest(1, coalesce(p_horas, 24)))
      and p.situacao = 'publicada'
      and public.link_para(o.id, 'instagram_story') is not null
  ),
  ainda_de_pe as (
    select r.*, coalesce(r.preco_publicado, r.preco_atual) as referencia
    from recentes r
    where r.disponivel
  )
  select
    a.publicado_em,
    a.titulo_curto,
    a.url_imagem,
    public.texto_do_story(a.titulo_curto, a.preco_atual, a.preco_original, a.desconto_percentual),
    a.url_afiliado,
    a.referencia,
    a.preco_atual,
    case
      when a.preco_atual > a.referencia then 'SUBIU desde o post — confira antes'
      when a.preco_atual < a.referencia then 'caiu mais ainda'
      else 'mesmo preço do post'
    end
  from ainda_de_pe a
  order by (a.preco_atual - a.referencia) asc, a.publicado_em desc;
$$;

create or replace function public.para_o_instagram(p_horas integer default 24)
returns table (
  nota integer,
  faixa text,
  produto text,
  foto text,
  chamada text,
  link_do_sticker text,
  economia numeric,
  por_que jsonb,
  publicado_em timestamptz
)
language sql
stable
security definer
set search_path to ''
as $$
  with recentes as (
    select p.publicado_em,
           o.id as oferta_id,
           o.preco_atual,
           o.preco_original,
           o.desconto_percentual,
           o.url_imagem,
           public.link_para(o.id, 'instagram_story') as url_afiliado,
           case when char_length(o.titulo) > 55
                then left(o.titulo, 52) || '...'
                else o.titulo end as titulo_curto
    from public.publicacoes p
    join public.ofertas o on o.id = p.oferta_id
    where p.publicado_em > now() - make_interval(hours => greatest(1, coalesce(p_horas, 24)))
      and p.situacao = 'publicada'
      and o.disponivel
      and public.link_para(o.id, 'instagram_story') is not null
  ),
  pontuadas as (
    select r.*, public.social_score(r.oferta_id) as s
    from recentes r
  )
  select (p.s->>'nota')::integer,
         p.s->>'faixa',
         p.titulo_curto,
         p.url_imagem,
         public.texto_do_story(p.titulo_curto, p.preco_atual, p.preco_original, p.desconto_percentual),
         p.url_afiliado,
         (p.s->>'economia')::numeric,
         p.s,
         p.publicado_em
  from pontuadas p
  order by (p.s->>'nota')::integer desc, p.publicado_em desc;
$$;

-- ---------------------------------------------------------------------------
-- O que ja esta etiquetado, e o que falta
-- ---------------------------------------------------------------------------

create or replace function public.rastreio_dos_destinos()
returns table (
  destino text,
  itens_etiquetados bigint,
  exemplo_de_etiqueta text
)
language sql
stable
security definer
set search_path to ''
as $$
  select l.destino, count(*), min(l.etiqueta)
  from public.links_por_destino l
  group by l.destino
  order by count(*) desc;
$$;

comment on function public.rastreio_dos_destinos() is
  'Quantos itens ja tem link etiquetado por destino. Enquanto estiver vazio, o painel do afiliado soma tudo junto.';

-- ---------------------------------------------------------------------------
-- Permissoes
-- ---------------------------------------------------------------------------

revoke all on function public.link_para(bigint, text) from public, anon;
revoke all on function public.link_destino_definir(text, text, text, text, text) from public, anon;
revoke all on function public.rastreio_dos_destinos() from public, anon;

grant execute on function public.link_para(bigint, text) to service_role, authenticated;
grant execute on function public.link_destino_definir(text, text, text, text, text) to service_role, authenticated;
grant execute on function public.rastreio_dos_destinos() to service_role, authenticated;
