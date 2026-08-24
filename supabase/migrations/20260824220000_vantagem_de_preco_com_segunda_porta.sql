-- Segunda porta: fundo historico vale tanto quanto desconto
--
-- Ate aqui o Baixou tinha porta unica: sem queda verificada de 15% contra o
-- proprio historico, recusa. Isso e mais rigido que o Radar Rota, que aprova
-- por desconto OU por competitividade — preco abaixo da propria referencia.
--
-- O efeito da porta unica: produto no menor preco que ja vimos, mas que chegou
-- la devagar, nunca vira post. E queda lenta e queda igual.
--
-- Duas decisoes que este arquivo carrega:
--
-- 1. A referencia e a MEDIANA DAS MEDIANAS DIARIAS, nao a mediana das
--    amostras. O coletor le de hora em hora; um preco que caiu e ficou enche o
--    historico de amostras no valor novo, a mediana das amostras persegue o
--    preco atual, e a pechincha some da conta justamente por ter durado. Com
--    um voto por dia, um dia inteiro a R$ 180 pesa igual a um dia inteiro a
--    R$ 134.
--
-- 2. Vendedor diferente nao e desconto. Quando a linha segue o vencedor da
--    vitrine, o anuncio troca de dono entre rodadas e a diferenca de preco
--    entre anunciantes vira "queda". Foi o caso de um ar-condicionado que
--    oscilou entre R$ 1.648 e R$ 3.516: 53% de nada.

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
  -- A leitura mais recente e o "agora"; o resto e a historia contra a qual ela
  -- e comparada.
  select h.preco, h.metadados->>'vendedor'
  into v_atual, v_vendedor_atual
  from public.historico_precos h
  where h.oferta_id = p_oferta_id
  order by h.observado_em desc
  limit 1;

  if v_atual is null then
    return jsonb_build_object('competitividade', 0, 'amostras_dias', 0, 'motivo', 'sem_leitura');
  end if;

  -- Um voto por dia. Ver comentario 1 no topo.
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

  -- Dois dias anteriores e o minimo para haver referencia. Com um so, qualquer
  -- numero seria opiniao sobre uma coincidencia.
  if v_dias < 2 or v_referencia is null or v_referencia <= 0 then
    return jsonb_build_object(
      'competitividade', 0, 'amostras_dias', coalesce(v_dias, 0), 'motivo', 'historico_curto'
    );
  end if;

  -- Ver comentario 2 no topo. Quando a informacao de vendedor nao existe
  -- (leituras antigas), a checagem e pulada em vez de chutar.
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
    when v_atual < v_minimo then 15            -- abaixo do melhor dia ja visto
    when v_atual <= v_referencia * 0.90 then 13 -- 10% abaixo da referencia
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
    'suspeita_troca_de_vendedor', false
  );
end;
$$;

comment on function public.ml_vantagem_de_preco(bigint) is
  'Competitividade contra a mediana das medianas diarias: 15 = abaixo do melhor dia, 13 = 10% abaixo da referencia. Zera quando o vendedor mudou.';

-- ---------------------------------------------------------------------------
-- Carimbo de "pronto para link" passa a ter validade
--
-- Antes o carimbo guardava o melhor desconto ja visto e nunca era revisto.
-- ml_prontos_para_link() misturava "esta caindo agora" com "caiu anteontem", e
-- gerar link para o segundo publicaria oferta que nao existe mais.
-- ---------------------------------------------------------------------------

create or replace function public.ml_item_sem_vantagem(p_id bigint)
returns void
language sql
security definer
set search_path to ''
as $$
  update public.itens_ml
  set pronto_em = null,
      pronto_pontuacao = null,
      pronto_desconto = null
  where id = p_id
    and url_afiliado is null
    and pronto_em is not null;
$$;

comment on function public.ml_item_sem_vantagem(bigint) is
  'Limpa o carimbo quando a leitura mais recente nao tem mais vantagem de preco. E o que mantem ml_prontos_para_link() uma lista viva.';

revoke all on function public.ml_vantagem_de_preco(bigint) from public, anon;
revoke all on function public.ml_item_sem_vantagem(bigint) from public, anon, authenticated;

grant execute on function public.ml_vantagem_de_preco(bigint) to service_role, authenticated;
grant execute on function public.ml_item_sem_vantagem(bigint) to service_role;
