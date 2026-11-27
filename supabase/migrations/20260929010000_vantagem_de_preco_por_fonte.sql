-- Vantagem de preco deixa de ser "a funcao do Mercado Livre usada por todos".
--
-- Como estava: `vantagem_de_preco(id)` era um wrapper de uma linha para
-- `ml_vantagem_de_preco(id)`. A Shopee chamava a funcao generica e era julgada
-- pela regua do ML sem que nada no banco dissesse isso.
--
-- Funcionava por acidente. A unica parte realmente especifica do ML e a trava
-- de troca de vendedor, e ela e inerte na Shopee porque nenhuma leitura da
-- Shopee traz `metadados->>'vendedor'` (conferido: 0 de ~114 mil leituras).
-- No dia em que a Shopee passar a mandar esse campo — ou em que alguem mudar o
-- coletor para mandar — a trava comeca a zerar competitividade da Shopee
-- inteira, calada, e o sintoma seria "a Shopee parou de publicar" sem nenhum
-- erro em lugar nenhum. E a mesma familia de falha que este projeto combate.
--
-- Como fica: UMA implementacao do calculo (`vantagem_de_preco_base`), com a
-- politica por fonte explicita no parametro. Sem duplicar 60 linhas de logica
-- de preco, que e o jeito garantido de as duas versoes divergirem.
--
-- COMPORTAMENTO HOJE: identico ao anterior, para as duas fontes. O ML continua
-- com a trava de vendedor ligada; a Shopee roda sem ela, que e exatamente o
-- que ja acontecia na pratica. Nada no que e publicado muda com esta migracao.

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

  -- Trava de troca de vendedor: so faz sentido onde o anuncio pode mudar de
  -- dono mantendo o mesmo id, como no Mercado Livre. A fonte decide.
  if p_checar_vendedor then
    select mode() within group (order by h.metadados->>'vendedor')
    into v_vendedor_antes
    from public.historico_precos h
    where h.oferta_id = p_oferta_id
      and h.metadados->>'vendedor' is not null
      and h.observado_em < (
        select max(h2.observado_em) from public.historico_precos h2 where h2.oferta_id = p_oferta_id
      );

    if v_vendedor_atual is not null
       and v_vendedor_antes is not null
       and v_vendedor_atual <> v_vendedor_antes then
      return jsonb_build_object(
        'competitividade', 0,
        'amostras_dias', v_dias,
        'referencia', round(v_referencia, 2),
        'preco_atual', round(v_atual, 2),
        'suspeita_troca_de_vendedor', true,
        'motivo', 'vendedor_mudou'
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

comment on function public.vantagem_de_preco_base(bigint, boolean) is
  'Nucleo do calculo de vantagem de preco. Nao chamar direto: use '
  'vantagem_de_preco(oferta_id), que escolhe a politica pela fonte da oferta.';

-- O ML mantem a trava de vendedor.
create or replace function public.ml_vantagem_de_preco(p_oferta_id bigint)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select public.vantagem_de_preco_base(p_oferta_id, true);
$function$;

-- A Shopee roda sem a trava: la o id do item nao troca de dono, e nenhuma
-- leitura traz vendedor. E o que ja acontecia de fato.
create or replace function public.shopee_vantagem_de_preco(p_oferta_id bigint)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select public.vantagem_de_preco_base(p_oferta_id, false);
$function$;

-- A porta de entrada despacha pela fonte da oferta, em vez de fingir que
-- existe uma regua so. Fonte desconhecida cai no caminho conservador (com
-- trava), porque errar para o lado de publicar menos e o certo aqui.
create or replace function public.vantagem_de_preco(p_oferta_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_slug text;
begin
  select f.slug into v_slug
  from public.ofertas o
  join public.fontes f on f.id = o.fonte_id
  where o.id = p_oferta_id;

  return case v_slug
    when 'shopee_open_api' then public.shopee_vantagem_de_preco(p_oferta_id)
    else public.ml_vantagem_de_preco(p_oferta_id)
  end;
end;
$function$;

-- Conferencia: as tres funcoes tem que existir e concordar entre si hoje.
-- Se a separacao mudou o resultado de alguma oferta, a migracao falha aqui em
-- vez de alterar em silencio o que chega no canal.
do $$
declare
  v_divergentes int;
begin
  if to_regprocedure('public.vantagem_de_preco_base(bigint, boolean)') is null
     or to_regprocedure('public.shopee_vantagem_de_preco(bigint)') is null
     or to_regprocedure('public.vantagem_de_preco(bigint)') is null then
    raise exception 'alguma das funcoes de vantagem nao foi criada';
  end if;

  select count(*) into v_divergentes
  from (
    select o.id
    from public.ofertas o
    join public.fontes f on f.id = o.fonte_id
    where f.slug = 'shopee_open_api'
      and public.vantagem_de_preco(o.id)->>'competitividade'
          is distinct from public.ml_vantagem_de_preco(o.id)->>'competitividade'
    limit 50
  ) d;

  if v_divergentes > 0 then
    raise exception
      'a separacao por fonte mudou a competitividade de % ofertas da Shopee; '
      'esperado zero mudanca de comportamento nesta migracao', v_divergentes;
  end if;
end $$;
