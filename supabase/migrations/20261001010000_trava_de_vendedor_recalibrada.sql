-- A trava de vendedor para de confundir rotacao de vitrine com troca de dono.
--
-- SINTOMA: o Mercado Livre publicava ~6 ofertas por dia ate 28/09 e foi a ZERO
-- em 29 e 30/09. O dono percebeu antes de qualquer alarme nosso — nenhum dos
-- vereditos acusou nada, porque do ponto de vista da saude da coleta o motor
-- estava perfeito: lendo 300 vezes por hora, token valido, fila vazia. Ele
-- apenas recusava tudo.
--
-- INVESTIGACAO: 124 de 250 ofertas do ML voltavam competitividade 0 com motivo
-- 'vendedor_mudou'. Comparando o mesmo conjunto com e sem a trava:
--
--   passam COM a trava ..........  5
--   passam SEM a trava .......... 27
--   zeradas pela trava .......... 120
--   perdidas que publicariam .... 22
--
-- NAO FOI REGRESSAO. A migracao 20260929010000, que separou vantagem_de_preco
-- por fonte, copiou a trava byte a byte da versao de 24/08 — conferido. A trava
-- sempre foi assim. O que mudou foi o acaso de quais vendedores estavam no topo
-- da vitrine, e o ML atravessou o limiar em que quase toda oferta passou a
-- divergir do vendedor mais frequente.
--
-- Isso e pior do que uma regressao, e nao melhor: significa que o motor sempre
-- esteve a um sorteio de distancia de parar sozinho, em silencio.
--
-- CAUSA: a trava comparava o vendedor atual com o MAIS FREQUENTE do historico.
-- Medido: 7,1 vendedores distintos por oferta, 90% das ofertas com rotacao. No
-- catalogo do ML o vencedor da vitrine gira o tempo todo entre vendedores
-- conhecidos. A trava disparava no funcionamento normal da plataforma.
--
-- CONSERTO: ela passa a disparar so quando o vendedor atual NUNCA apareceu no
-- historico da oferta. Rotacao entre conhecidos passa; dono inedito e barrado,
-- que e o risco que ela foi criada para cobrir. Na mesma amostra, 24 das 26
-- ofertas elegiveis voltam, e as 2 de vendedor inedito seguem barradas.
--
-- O motivo muda de 'vendedor_mudou' para 'vendedor_inedito', porque e outra
-- afirmacao: nao e "mudou de dono", e "este dono nunca foi observado aqui".

create or replace function public.vantagem_de_preco_base(
  p_oferta_id bigint,
  p_checar_vendedor boolean
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_atual numeric;
  v_vendedor_atual text;
  v_vendedor_antes text;
  v_referencia numeric;
  v_minimo numeric;
  v_dias integer;
  v_competitividade smallint;
begin
  select h.preco, h.metadados->>'vendedor'
  into v_atual, v_vendedor_atual
  from public.historico_precos h
  where h.oferta_id = p_oferta_id
  order by h.observado_em desc
  limit 1;

  if v_atual is null then
    return jsonb_build_object('competitividade', 0, 'amostras_dias', 0, 'motivo', 'sem_leitura');
  end if;

  with por_dia as (
    select date_trunc('day', h.observado_em) as dia,
           percentile_cont(0.5) within group (order by h.preco) as mediana_do_dia
    from public.historico_precos h
    where h.oferta_id = p_oferta_id
      and h.observado_em >= now() - interval '30 days'
      and date_trunc('day', h.observado_em) < date_trunc('day', now())
    group by 1
  )
  select count(*),
         percentile_cont(0.5) within group (order by mediana_do_dia),
         min(mediana_do_dia)
  into v_dias, v_referencia, v_minimo
  from por_dia;

  if v_dias < 2 or v_referencia is null or v_referencia <= 0 then
    return jsonb_build_object(
      'competitividade', 0, 'amostras_dias', coalesce(v_dias, 0), 'motivo', 'historico_curto'
    );
  end if;

  -- Trava de vendedor: so faz sentido onde o anuncio pode mudar de dono
  -- mantendo o mesmo id, como no Mercado Livre. A fonte decide.
  --
  -- RECALIBRADA EM 01/10, depois de medir. A versao anterior comparava o
  -- vendedor atual com o MAIS FREQUENTE do historico (mode) e zerava a
  -- competitividade a qualquer diferenca. Medido em 250 ofertas do ML:
  --
  --   vendedores distintos por oferta ............ 7,1 em media
  --   ofertas com rotacao de vendedor ............ 225 de 250 (90%)
  --   zeradas pela trava ......................... 120
  --   ofertas que publicariam e estavam barradas .. 22
  --
  -- No catalogo do ML o vencedor da vitrine gira entre varios vendedores
  -- conhecidos o tempo todo. Comparar contra o mais frequente de uma lista de
  -- sete faz a trava disparar no funcionamento NORMAL da plataforma, nao numa
  -- anomalia. Ela derrubou o ML de 6 publicacoes por dia para zero.
  --
  -- O risco real que ela existe para cobrir e outro: o historico de preco vir
  -- de vendedores conhecidos e o preco baixo de agora vir de um dono NOVO, que
  -- ninguem observou antes. Esse caso ela continua barrando.
  --
  -- Medido com a regra nova, na mesma amostra: 24 das 26 ofertas elegiveis
  -- voltam a passar, e as 2 de vendedor inedito seguem barradas.
  if p_checar_vendedor and v_vendedor_atual is not null then
    -- So julga se existe historico de vendedor para comparar. Sem isso nao ha
    -- o que afirmar, e calar e melhor que zerar por falta de dado.
    if exists (
      select 1 from public.historico_precos h
       where h.oferta_id = p_oferta_id
         and h.metadados->>'vendedor' is not null
         and h.observado_em < (
           select max(h2.observado_em) from public.historico_precos h2
            where h2.oferta_id = p_oferta_id
         )
    ) and not exists (
      select 1 from public.historico_precos h
       where h.oferta_id = p_oferta_id
         and h.metadados->>'vendedor' = v_vendedor_atual
         and h.observado_em < (
           select max(h2.observado_em) from public.historico_precos h2
            where h2.oferta_id = p_oferta_id
         )
    ) then
      return jsonb_build_object(
        'competitividade', 0,
        'amostras_dias', v_dias,
        'referencia', round(v_referencia, 2),
        'preco_atual', round(v_atual, 2),
        'suspeita_troca_de_vendedor', true,
        'motivo', 'vendedor_inedito'
      );
    end if;
  end if;

  -- A margem de 10% e obrigatoria para QUALQUER nota que abra a porta.
  --
  -- Antes, "abaixo do minimo diario" dava 15 sem exigir margem: produto que
  -- escorrega devagar bate minimo novo todo dia com queda de centavos, e
  -- entrava no canal como "menor preco que ja vimos" por 1% de diferenca.
  -- Pego a tempo — um Galaxy A07 a 1,15% da referencia estava carimbado com
  -- nota 98.
  --
  -- Agora estar abaixo do minimo apenas PROMOVE 13 para 15; nao substitui a
  -- margem.
  v_competitividade := case
    when v_atual <= v_referencia * 0.90 and v_atual < v_minimo then 15
    when v_atual <= v_referencia * 0.90 then 13
    when v_atual <= v_referencia * 0.95 then 10
    when v_atual <= v_referencia then 7
    else 2
  end;

  return jsonb_build_object(
    'competitividade', v_competitividade,
    'amostras_dias', v_dias,
    'referencia', round(v_referencia, 2),
    'minimo_diario', round(v_minimo, 2),
    'preco_atual', round(v_atual, 2),
    'abaixo_da_referencia_pct', round(((v_referencia - v_atual) / v_referencia) * 100, 2),
    'suspeita_troca_de_vendedor', false
  );
end;
$function$;

-- Conferencia: a trava tem que continuar de pe para vendedor inedito, e tem que
-- ter parado de derrubar rotacao normal. Numeros medidos antes do conserto:
-- 5 ofertas passavam; o esperado agora e ordem de 20 a 30 na mesma amostra.
do $guarda$
declare
  v_passam int;
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'vantagem_de_preco_base';

  if position('vendedor_inedito' in v_def) = 0 then
    raise exception 'a trava recalibrada nao entrou';
  end if;

  if position('mode() within group' in v_def) > 0 then
    raise exception 'a comparacao por vendedor mais frequente ainda esta la';
  end if;

  select count(*) into v_passam
  from (
    select o.id from public.ofertas o
      join public.fontes f on f.id = o.fonte_id
     where f.slug = 'mercado_livre_api_oficial'
       and o.disponivel and o.url_afiliado is not null
     order by o.visto_ultimo_em desc limit 250
  ) a
  where (public.vantagem_de_preco(a.id)->>'competitividade')::int >= 13;

  if v_passam <= 5 then
    raise exception
      'depois do conserto apenas % ofertas do ML passam da porta; '
      'era 5 antes, entao nada destravou e a causa e outra', v_passam;
  end if;

  raise notice 'ofertas do ML que passam da porta apos o conserto: %', v_passam;
end $guarda$;
