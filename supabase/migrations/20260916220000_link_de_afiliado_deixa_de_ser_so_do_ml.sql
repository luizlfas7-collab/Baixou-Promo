-- ---------------------------------------------------------------------------
-- O link de afiliado deixa de ser so do Mercado Livre.
--
-- para_compartilhar() e resumo_do_dia() liam o link em itens_ml, a watchlist
-- do ML. Funcionou enquanto o ML era a unica fonte. Com a Shopee entrando,
-- esse join vira um filtro silencioso: item que nao esta em itens_ml nao tem
-- linha no join, `i.url_afiliado is not null` derruba ele, e a oferta Shopee
-- simplesmente NAO APARECE no resumo. Sem erro, sem aviso — some.
--
-- Falha silenciosa e a pior especie: o dono acha que o resumo esta completo.
--
-- A correcao nao e alargar o join, e parar de perguntar para a tabela errada.
-- O link de afiliado da oferta mora em ofertas.url_afiliado, gravado por
-- registrar_oferta() a partir do que o coletor mandou — qualquer coletor, de
-- qualquer fonte. Conferido em 16/09: as 94 publicacoes do historico tem
-- ofertas.url_afiliado preenchido, contra 93 em itens_ml. A coluna generica
-- ja era a mais completa das duas mesmo antes da Shopee existir.
--
-- A garantia de que o link e do dono nao enfraquece: registrar_oferta() so
-- enfileira com url_afiliado preenchido ('sem_link_de_afiliado'), e payload.ts
-- recusa dominio fora da allowlist. Este arquivo so troca a fonte da leitura.
-- ---------------------------------------------------------------------------

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
           -- Generico por fonte: o link e da oferta, nao da watchlist do ML.
           o.url_afiliado,
           -- Titulo curto: nome longo demais afoga o preco, que e a noticia.
           case when char_length(o.titulo) > 70
                then left(o.titulo, 67) || '...'
                else o.titulo end as titulo_curto
    from public.publicacoes p
    join public.ofertas o on o.id = p.oferta_id
    where p.publicado_em > now() - make_interval(hours => greatest(1, coalesce(p_horas, 24)))
      and o.url_afiliado is not null
  )
  select
    r.publicado_em,
    r.titulo_curto,
    r.preco_atual,
    r.desconto_percentual,
    r.url_afiliado,

    -- WhatsApp: *negrito* e _italico_ sao a marcacao dele. Link no fim, porque
    -- o app so gera a previa do ULTIMO link da mensagem.
    E'\U0001F525 ' || r.titulo_curto || E'\n\n' ||
    case when r.preco_original is not null and r.preco_original > r.preco_atual
         then 'De R$ ' || public.dinheiro(r.preco_original) || ' por *R$ '
              || public.dinheiro(r.preco_atual) || '*' || E'\n'
         else '*R$ ' || public.dinheiro(r.preco_atual) || '*' || E'\n'
    end ||
    case when r.desconto_percentual is not null
         then E'\U0001F4C9 ' || to_char(r.desconto_percentual, 'FM990') || '% abaixo do que já vimos' || E'\n'
         else '' end ||
    E'\n\U0001F449 ' || r.url_afiliado || E'\n\n_PUBLICIDADE • LINK DE AFILIADO_',

    -- Instagram: link nao clica na legenda. Por isso o texto manda para a bio
    -- em vez de fingir que o link funciona ali.
    E'\U0001F525 ' || r.titulo_curto || E'\n\n' ||
    'R$ ' || public.dinheiro(r.preco_atual) ||
    case when r.desconto_percentual is not null
         then ' — ' || to_char(r.desconto_percentual, 'FM990') || '% abaixo do preço de costume'
         else '' end || E'\n\n' ||
    E'Link na bio \U0001F517\n\n' ||
    'PUBLICIDADE • LINK DE AFILIADO' || E'\n\n' ||
    '#promocao #oferta #desconto #achadinhos #baixou',

    -- X: 280 caracteres contando o link. Corta o titulo antes de estourar.
    left(
      E'\U0001F525 ' || left(r.titulo_curto, 90) || E'\n' ||
      'R$ ' || public.dinheiro(r.preco_atual) ||
      case when r.desconto_percentual is not null
           then ' (-' || to_char(r.desconto_percentual, 'FM990') || '%)'
           else '' end || E'\n' ||
      r.url_afiliado || E'\n#publicidade',
      280)
  from recentes r
  order by r.publicado_em desc;
$$;

comment on function public.para_compartilhar(integer) is
  'As ofertas ja publicadas, vestidas para WhatsApp, Instagram e X. Quem publica e o dono, a mao. Serve qualquer fonte.';

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
    select o.titulo, o.preco_atual, o.desconto_percentual, o.url_afiliado
    from public.publicacoes p
    join public.ofertas o on o.id = p.oferta_id
    where p.publicado_em > now() - interval '24 hours'
      and o.url_afiliado is not null
    order by o.desconto_percentual desc nulls last
    limit greatest(1, least(coalesce(p_quantas, 5), 10))
  loop
    v_n := v_n + 1;
    v_linhas := v_linhas
      || v_n || '. ' || case when char_length(v_reg.titulo) > 55
                             then left(v_reg.titulo, 52) || '...'
                             else v_reg.titulo end || E'\n'
      || '   R$ ' || public.dinheiro(v_reg.preco_atual)
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
  'As melhores ofertas do dia num texto so, pronto para encaminhar. Lista viaja; anuncio avulso nao. Serve qualquer fonte.';

-- ---------------------------------------------------------------------------
-- A conferencia de integridade do link vira funcao do banco.
--
-- Ela existia so como consulta solta no check-in de vigilancia, escrita contra
-- itens_ml e aceitando apenas meli.la. Uma barreira que mora num prompt nao e
-- barreira: nao roda sozinha, nao versiona, e some quando quem a escreveu
-- esquecer. Aqui ela fica no banco, generica por fonte, e passa a valer para
-- a Shopee no mesmo instante em que o primeiro item Shopee for publicado.
--
-- 'dominio_do_botao' sai junto de proposito: quando um dominio novo aparecer,
-- o dono ve QUAL, em vez de so um contador subindo.
-- ---------------------------------------------------------------------------

create or replace function public.integridade_do_link(p_horas integer default 48)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  with pub as (
    select p.id,
           p.publicado_em,
           f.slug as fonte,
           o.url_afiliado as url_cadastrada,
           p.snapshot_payload #>> '{reply_markup,inline_keyboard,0,0,url}' as url_botao
    from public.publicacoes p
    join public.ofertas o on o.id = p.oferta_id
    join public.fontes f on f.id = o.fonte_id
    where p.publicado_em > now() - make_interval(hours => greatest(1, coalesce(p_horas, 48)))
  ),
  julgada as (
    select pub.*,
           case
             when pub.url_botao is null then 'sem_link'
             when pub.url_botao is distinct from pub.url_cadastrada then 'link_trocado'
             -- A allowlist de dominios vive em _compartilhado/afiliados.ts. Aqui
             -- so se confere o encurtador, que e o que o leitor enxerga e clica.
             when split_part(split_part(pub.url_botao, '://', 2), '/', 1)
                  not in ('meli.la', 's.shopee.com.br', 'tidd.ly', 'amzn.to')
               then 'fora_do_dominio'
             else 'ok'
           end as veredito
    from pub
  )
  select jsonb_build_object(
    'janela_horas', greatest(1, coalesce(p_horas, 48)),
    'publicacoes', count(*),
    'ok', count(*) filter (where veredito = 'ok'),
    'sem_link', count(*) filter (where veredito = 'sem_link'),
    'link_trocado', count(*) filter (where veredito = 'link_trocado'),
    'fora_do_dominio', count(*) filter (where veredito = 'fora_do_dominio'),
    'por_fonte', (
      select coalesce(jsonb_object_agg(fonte, n), '{}'::jsonb)
      from (select fonte, count(*) as n from julgada group by fonte) t
    ),
    -- Contador nao conserta nada. Quem conserta e o id e a URL do caso.
    'suspeitas', coalesce(
      (select jsonb_agg(jsonb_build_object(
                'publicacao_id', id, 'fonte', fonte, 'veredito', veredito,
                'url_botao', url_botao, 'url_cadastrada', url_cadastrada,
                'dominio_do_botao', split_part(split_part(url_botao, '://', 2), '/', 1))
              order by publicado_em desc)
       from julgada where veredito <> 'ok'), '[]'::jsonb)
  )
  from julgada;
$$;

comment on function public.integridade_do_link(integer) is
  'A publicacao aponta para o link de afiliado cadastrado da propria oferta? Vale para qualquer fonte.';

revoke all on function public.integridade_do_link(integer) from public, anon;
grant execute on function public.integridade_do_link(integer) to service_role, authenticated;
