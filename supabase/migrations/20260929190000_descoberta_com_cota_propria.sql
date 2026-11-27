-- A descoberta ganha um teto proprio, separado do teto da watchlist.
--
-- Sintoma que trouxe isto: em 29/09 a descoberta inseriu 287 itens sem link de
-- afiliado num unico dia. Item sem link nao publica — ele existe para OBSERVAR
-- preco ate provar que merece um link (ml_prontos_para_link). Mas ele e lido
-- pelo mesmo orcamento de quem ja rende: medido hoje, 276 leituras/hora.
--
--   317 itens com link            -> 317/276 = 1,15h de revisita
--   317 + 104 sem link            -> 421/276 = 1,53h
--   317 + 287 sem link (o que era) -> 604/276 = 2,19h
--
-- O ultimo caso estoura o alarme de revisita esticada (2,00h) e, pior, atrasa
-- a leitura de TODO produto que pode virar comissao. O teto unico de 500 nao
-- protegia contra isso: ele conta os dois grupos juntos, entao a descoberta
-- podia consumir a watchlist inteira com itens que nao rendem.
--
-- Por que nao zerar a descoberta: ela e o funil. Item precisa de >=2 dias
-- completos de historico para ser julgado (senao cai em 'historico_curto'),
-- logo precisa ficar observando alguns dias antes de provar qualquer coisa.
-- Cortar o funil e garantir que a lista de candidatos a link nunca encha.
--
-- Entao: cota propria. A descoberta pode manter ate 110 itens sem link em
-- observacao simultanea — cabe no orcamento (427/276 = 1,55h, com folga ate o
-- alarme de 2,00h) e e funil suficiente para alimentar a lista de candidatos.

create or replace function public.watchlist_teto_sem_link()
returns integer
language sql
immutable
set search_path to ''
as $function$ select 110 $function$;

comment on function public.watchlist_teto_sem_link() is
  'Quantos itens SEM link de afiliado podem ficar em observacao ao mesmo tempo. '
  'Eles sao o funil da descoberta, mas gastam o mesmo orcamento de leitura de '
  'quem rende — por isso tem teto proprio, menor que o da watchlist.';

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
begin
  select count(*) filter (where habilitado),
         count(*) filter (where habilitado and url_afiliado is null)
  into v_habilitados, v_sem_link
  from public.itens_ml;

  v_espaco_total    := public.watchlist_teto() - v_habilitados;
  v_espaco_sem_link := public.watchlist_teto_sem_link() - v_sem_link;

  -- Duas paredes, e a resposta diz QUAL delas parou. Devolver so
  -- 'watchlist_cheia' para os dois casos esconderia a diferenca entre "nao
  -- cabe mais nada" e "o funil ja esta no limite dele" — e sao decisoes
  -- diferentes: a primeira pede subir o teto, a segunda pede gerar link para
  -- quem ja provou, liberando vaga.
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
      'prontos_para_link', (
        select count(*) from public.itens_ml
         where url_afiliado is null and pronto_em is not null
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
    'prontos_para_link', (
      select count(*) from public.itens_ml
       where url_afiliado is null and pronto_em is not null
    ),
    'teto', public.watchlist_teto()
  );
end;
$function$;

-- Conferencia: a cota tem que ser respeitada a partir de agora, e a funcao
-- tem que continuar existindo com a assinatura que o pg_cron chama.
do $$
declare
  v_sem_link int;
begin
  if to_regprocedure('public.watchlist_teto_sem_link()') is null then
    raise exception 'watchlist_teto_sem_link nao foi criada';
  end if;

  if to_regprocedure('public.descoberta_coletar(integer)') is null then
    raise exception 'descoberta_coletar perdeu a assinatura que o agendamento chama';
  end if;

  select count(*) into v_sem_link
  from public.itens_ml where habilitado and url_afiliado is null;

  -- Nao falha se hoje ja estiver acima do teto: os itens de hoje entraram
  -- antes desta regra existir e vao envelhecer ate provar ou serem recolhidos.
  -- Falha se a cota estiver absurda, que seria erro de digitacao no teto.
  if public.watchlist_teto_sem_link() >= public.watchlist_teto() then
    raise exception 'a cota sem link (%) nao pode ser >= o teto da watchlist (%)',
      public.watchlist_teto_sem_link(), public.watchlist_teto();
  end if;

  raise notice 'cota sem link = %, ocupacao atual = %',
    public.watchlist_teto_sem_link(), v_sem_link;
end $$;
