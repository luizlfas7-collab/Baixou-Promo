-- Pacote de compartilhamento: a mesma oferta, pronta para outras redes
--
-- O gargalo do Baixou nao e producao, e distribuicao. Em 7 dias, 24 posts
-- geraram 3 cliques — o canal publica bem e quase ninguem le. Fazer MAIS
-- conteudo resolveria um problema que nao existe.
--
-- Entao aqui nao se produz nada novo: pega-se a oferta que JA foi publicada e
-- veste-se ela para os lugares onde o dono ja tem gente. Quem publica e ele,
-- a mao. E de proposito: automatizar postagem em WhatsApp e Instagram custa a
-- conta, e ele acabou de tomar um aviso do Mercado Livre.
--
-- A linha de PUBLICIDADE vai em todo formato. Exigencia legal nao muda de
-- plataforma, e o leitor do WhatsApp merece a mesma honestidade do leitor do
-- Telegram.

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
           o.titulo,
           o.preco_atual,
           o.preco_original,
           o.desconto_percentual,
           i.url_afiliado,
           -- Titulo curto: nome longo demais afoga o preco, que e a noticia.
           case when char_length(o.titulo) > 70
                then left(o.titulo, 67) || '...'
                else o.titulo end as titulo_curto
    from public.publicacoes p
    join public.ofertas o on o.id = p.oferta_id
    left join public.itens_ml i on i.produto_catalogo = o.id_externo
    where p.publicado_em > now() - make_interval(hours => greatest(1, coalesce(p_horas, 24)))
      and i.url_afiliado is not null
  )
  select
    r.publicado_em,
    r.titulo_curto,
    r.preco_atual,
    r.desconto_percentual,
    r.url_afiliado,

    -- WhatsApp: *negrito* e _italico_ sao a marcacao dele. Link no fim, porque
    -- o app so gera a previa do ultimo link da mensagem.
    E'\U0001F525 ' || r.titulo_curto || E'\n\n' ||
    case when r.preco_original is not null and r.preco_original > r.preco_atual
         then 'De R$ ' || to_char(r.preco_original, 'FM999G999D00') || ' por *R$ '
              || to_char(r.preco_atual, 'FM999G999D00') || '*' || E'\n'
         else '*R$ ' || to_char(r.preco_atual, 'FM999G999D00') || '*' || E'\n'
    end ||
    case when r.desconto_percentual is not null
         then E'\U0001F4C9 ' || to_char(r.desconto_percentual, 'FM990') || '% abaixo do que já vimos' || E'\n'
         else '' end ||
    E'\n\U0001F449 ' || r.url_afiliado || E'\n\n_PUBLICIDADE • LINK DE AFILIADO_',

    -- Instagram: link nao clica na legenda. Por isso o texto manda para a bio
    -- em vez de fingir que o link funciona ali.
    E'\U0001F525 ' || r.titulo_curto || E'\n\n' ||
    'R$ ' || to_char(r.preco_atual, 'FM999G999D00') ||
    case when r.desconto_percentual is not null
         then ' — ' || to_char(r.desconto_percentual, 'FM990') || '% abaixo do preço de costume'
         else '' end || E'\n\n' ||
    E'Link na bio \U0001F517\n\n' ||
    'PUBLICIDADE • LINK DE AFILIADO' || E'\n\n' ||
    '#promocao #oferta #desconto #achadinhos #baixou',

    -- X: 280 caracteres contando o link. Corta o titulo antes de estourar.
    left(
      E'\U0001F525 ' || left(r.titulo_curto, 90) || E'\n' ||
      'R$ ' || to_char(r.preco_atual, 'FM999G999D00') ||
      case when r.desconto_percentual is not null
           then ' (-' || to_char(r.desconto_percentual, 'FM990') || '%)'
           else '' end || E'\n' ||
      r.url_afiliado || E'\n#publicidade',
      280)
  from recentes r
  order by r.publicado_em desc;
$$;

comment on function public.para_compartilhar(integer) is
  'As ofertas ja publicadas, vestidas para WhatsApp, Instagram e X. Quem publica e o dono, a mao.';

-- ---------------------------------------------------------------------------
-- Resumo do dia
--
-- Lista se encaminha; anuncio avulso nao. Um "as melhores de hoje" viaja de
-- grupo em grupo de um jeito que oferta solta nunca viaja.
-- ---------------------------------------------------------------------------

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
    select o.titulo, o.preco_atual, o.desconto_percentual, i.url_afiliado
    from public.publicacoes p
    join public.ofertas o on o.id = p.oferta_id
    left join public.itens_ml i on i.produto_catalogo = o.id_externo
    where p.publicado_em > now() - interval '24 hours'
      and i.url_afiliado is not null
    order by o.desconto_percentual desc nulls last
    limit greatest(1, least(coalesce(p_quantas, 5), 10))
  loop
    v_n := v_n + 1;
    v_linhas := v_linhas
      || v_n || '. ' || case when char_length(v_reg.titulo) > 55
                             then left(v_reg.titulo, 52) || '...'
                             else v_reg.titulo end || E'\n'
      || '   R$ ' || to_char(v_reg.preco_atual, 'FM999G999D00')
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

comment on function public.resumo_do_dia(integer) is
  'As melhores ofertas do dia num texto so, pronto para encaminhar. Lista viaja; anuncio avulso nao.';

revoke all on function public.para_compartilhar(integer) from public, anon;
revoke all on function public.resumo_do_dia(integer) from public, anon;

grant execute on function public.para_compartilhar(integer) to service_role, authenticated;
grant execute on function public.resumo_do_dia(integer) to service_role, authenticated;

-- ---------------------------------------------------------------------------
-- Correcao aplicada logo apos o primeiro teste
--
-- O to_char usa lc_numeric do servidor, que aqui e americano: saia
-- "R$ 887.78". Preco com ponto no lugar da virgula denuncia robo mal feito
-- antes de qualquer outra coisa que o texto diga.
--
-- public.dinheiro() monta com separadores literais e troca os dois de lugar.
-- Deterministico, sem depender de locale. Todos os formatos acima passaram a
-- usa-la.
-- ---------------------------------------------------------------------------

create or replace function public.dinheiro(p_valor numeric)
returns text
language sql
immutable
set search_path to ''
as $$
  select case when p_valor is null then ''
         else translate(to_char(round(p_valor, 2), 'FM9,999,990.00'), '.,', ',.')
         end;
$$;

comment on function public.dinheiro(numeric) is
  'Formata em real brasileiro: 1234.5 vira 1.234,50. Nao depende de lc_numeric.';

revoke all on function public.dinheiro(numeric) from public, anon;
grant execute on function public.dinheiro(numeric) to service_role, authenticated;
