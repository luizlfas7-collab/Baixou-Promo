-- Margem real na porta de patamar, e carimbo que aceita vantagem sem desconto
--
-- Duas correcoes que sairam de testar a migracao anterior contra dados reais.

-- ---------------------------------------------------------------------------
-- 1. O carimbo nunca saia pela porta de patamar
--
-- ml_item_pronto_para_link comparava `p_desconto > pronto_desconto`. Aprovado
-- por patamar chega SEM desconto entre leituras, e comparar null contra
-- qualquer coisa devolve null — que e falso. O carimbo simplesmente nao
-- acontecia, e ml_prontos_para_link() ficava vazia para esse caminho inteiro.
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
      pronto_desconto = round(coalesce(p_desconto, 0), 2)
  where id = p_id
    and url_afiliado is null
    and coalesce(p_desconto, 0) >= coalesce(pronto_desconto, -1);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Estar abaixo do minimo nao substitui margem
--
-- A nota 15 era dada por "abaixo do minimo diario" sem exigir distancia
-- nenhuma da referencia. Produto que escorrega devagar bate minimo novo todo
-- dia com queda de centavos — e entrava no canal como "menor preco que ja
-- vimos" por 1% de diferenca.
--
-- Pego a tempo: um Galaxy A07 a 1,15% da referencia estava carimbado com nota
-- 98, pronto para virar post. Agora a margem de 10% e obrigatoria em qualquer
-- nota que abra a porta; estar abaixo do minimo apenas promove 13 para 15.
-- ---------------------------------------------------------------------------

create or replace function public.ml_vantagem_de_preco(p_oferta_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
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

  -- Um voto por dia: o coletor le de hora em hora, e preco que caiu e ficou
  -- encheria a mediana de amostras no valor novo, fazendo a pechincha sumir da
  -- conta justamente por ter durado.
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

  -- Vendedor diferente nao e desconto: quando a linha segue o vencedor da
  -- vitrine, a diferenca entre anunciantes viraria "queda".
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
$$;

revoke all on function public.ml_item_pronto_para_link(bigint, numeric, numeric) from public, anon, authenticated;
revoke all on function public.ml_vantagem_de_preco(bigint) from public, anon;

grant execute on function public.ml_item_pronto_para_link(bigint, numeric, numeric) to service_role;
grant execute on function public.ml_vantagem_de_preco(bigint) to service_role, authenticated;
