-- O funil de links passa a girar, em vez de entupir.
--
-- Como o funil funciona: a descoberta poe produtos na watchlist SEM link de
-- afiliado, so para observar preco. Quando um deles prova vantagem real, ele e
-- carimbado (pronto_em) e aparece em ml_prontos_para_link() — a lista do que
-- merece o dono ir no painel do ML gerar o link. Gerado o link, o produto
-- passa a poder publicar e virar comissao.
--
-- Dois defeitos impediam esse funil de entregar alguma coisa:
--
-- 1. ENTUPIMENTO. Item sem link entrava e nunca saia. Com a cota de 110 vagas,
--    bastavam 110 produtos medianos ocupando lugar para a descoberta parar de
--    trazer qualquer coisa nova — para sempre, e em silencio. Hoje ja estamos
--    em 104 de 110, todos criados no mesmo dia: em poucos dias a cota travaria.
--
-- 2. INVISIBILIDADE. A lista existe desde 02/09 e nunca foi olhada por
--    ninguem, porque nada a mostrava. Funil que ninguem ve e funil que nao
--    existe.
--
-- Este arquivo conserta o (1) e prepara o (2) devolvendo a lista dentro do
-- resumo que o vigia ja publica.
--
-- A regra de reciclagem: um produto sem link que ficou 7 dias na observacao e
-- nunca foi carimbado perdeu a vaga. Sete dias e generoso de proposito — sao
-- precisos 2 dias completos de historico so para ele deixar de cair em
-- 'historico_curto', entao ele ainda tem uns 5 dias de chances reais de provar
-- vantagem antes de sair. Quem ESTA carimbado nunca e reciclado: aquele e
-- candidato vivo esperando a decisao comercial do dono.
--
-- Nada e apagado. habilitado = false com o motivo escrito, reversivel por
-- ml_item_vincular (que ja religa o item ao receber o link).

create or replace function public.descoberta_reciclar(p_dias integer default 7)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_reciclados integer;
  v_dias integer := greatest(2, coalesce(p_dias, 7));
begin
  with soltos as (
    select i.id
    from public.itens_ml i
    where i.habilitado
      and i.url_afiliado is null
      and i.pronto_em is null
      and i.criado_em < now() - make_interval(days => v_dias)
    for update skip locked
  ),
  recolhidos as (
    update public.itens_ml i
       set habilitado = false,
           ultimo_erro = format(
             'reciclado em %s: %s dias em observacao sem nunca provar vantagem. '
             'A vaga voltou para a cota da descoberta. Religa sozinho se ganhar link.',
             to_char(now(), 'DD/MM HH24:MI'), v_dias)
      from soltos s
     where i.id = s.id
    returning 1
  )
  select count(*) into v_reciclados from recolhidos;

  return jsonb_build_object(
    'reciclados', v_reciclados,
    'dias', v_dias,
    'sem_link_agora', (
      select count(*) from public.itens_ml where habilitado and url_afiliado is null
    ),
    'aguardando_seu_link', (
      select count(*) from public.itens_ml
       where habilitado and url_afiliado is null and pronto_em is not null
    )
  );
end;
$function$;

comment on function public.descoberta_reciclar(integer) is
  'Devolve a vaga de quem ficou dias observando sem nunca provar vantagem. '
  'Nunca recicla item carimbado: aquele e candidato vivo esperando link.';

revoke all on function public.descoberta_reciclar(integer) from public, anon, authenticated;
grant execute on function public.descoberta_reciclar(integer) to service_role;

-- ---------------------------------------------------------------------------
-- A descoberta recicla ANTES de medir o espaco que tem.
--
-- Fica no mesmo agendamento que ja roda de hora em hora: nao adiciona cron
-- novo, e garante que a vaga liberada seja usada na mesma passada.
-- ---------------------------------------------------------------------------

create or replace function public.descoberta_coletar(p_limite_novos integer default 15)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_pendente record;
  v_corpo text;
  v_status integer;
  v_encontrados integer;
  v_inseridos integer;
  v_total_novos integer := 0;
  v_paginas integer := 0;
  v_espaco integer;
  v_espaco_total integer;
  v_espaco_sem_link integer;
  v_habilitados integer;
  v_sem_link integer;
  v_reciclagem jsonb;
begin
  v_reciclagem := public.descoberta_reciclar(7);

  select count(*) filter (where habilitado),
         count(*) filter (where habilitado and url_afiliado is null)
  into v_habilitados, v_sem_link
  from public.itens_ml;

  v_espaco_total    := public.watchlist_teto() - v_habilitados;
  v_espaco_sem_link := public.watchlist_teto_sem_link() - v_sem_link;
  v_espaco := least(v_espaco_total, v_espaco_sem_link);

  if v_espaco <= 0 then
    return jsonb_build_object(
      'situacao', case when v_espaco_total <= 0
                       then 'watchlist_cheia'
                       else 'cota_de_observacao_cheia' end,
      'teto', public.watchlist_teto(),
      'habilitados', v_habilitados,
      'teto_sem_link', public.watchlist_teto_sem_link(),
      'sem_link', v_sem_link,
      'reciclagem', v_reciclagem,
      'aguardando_seu_link', (
        select count(*) from public.itens_ml
         where habilitado and url_afiliado is null and pronto_em is not null
      )
    );
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
        select null, null, 'Descoberta', null, n.catalogo, 50, now()
        from novos n
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
    'sem_link', (select count(*) from public.itens_ml where habilitado and url_afiliado is null),
    'teto_sem_link', public.watchlist_teto_sem_link(),
    'reciclagem', v_reciclagem,
    'aguardando_seu_link', (
      select count(*) from public.itens_ml
       where habilitado and url_afiliado is null and pronto_em is not null
    ),
    'teto', public.watchlist_teto()
  );
end;
$function$;

-- Conferencia: a reciclagem nao pode encostar em quem tem link nem em quem ja
-- foi carimbado. Se encostar, o funil perde exatamente o que ele produz.
do $$
declare
  v_vitima int;
begin
  select count(*) into v_vitima
  from public.itens_ml
  where not habilitado
    and (url_afiliado is not null or pronto_em is not null)
    and ultimo_erro like 'reciclado em%';

  if v_vitima > 0 then
    raise exception
      'a reciclagem desabilitou % item(ns) que tinham link ou carimbo; '
      'esses nunca podem sair da observacao', v_vitima;
  end if;

  if to_regprocedure('public.descoberta_reciclar(integer)') is null then
    raise exception 'descoberta_reciclar nao foi criada';
  end if;
end $$;
