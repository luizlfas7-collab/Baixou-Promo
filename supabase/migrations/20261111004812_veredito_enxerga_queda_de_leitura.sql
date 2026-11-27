-- O veredito por fonte so sabia enxergar CEGUEIRA TOTAL.
--
-- MEDIDO em 11/11: a Shopee passou de 05 a 11/11 devolvendo "error [10000]:
-- System Error" em metade das palavras-chave. A leitura caiu de 57.500 para
-- 30.450 itens/dia em 09/11 e para 24.600 em 10/11 — 57% da capacidade embora
-- — e `veredito` seguiu 'saudavel' em TODAS as rodadas, porque a unica
-- pergunta que ele fazia era "fez alguma leitura recentemente?". Fez: 8 das 20
-- palavras funcionavam, e isso bastava para parecer saude.
--
-- Pior: `falhas_1h` JA ERA calculado e exposto ao lado do veredito. Em 11/11
-- 00:16 a Shopee mostrava falhas_1h=4, rodadas_1h=4 — cem por cento das
-- rodadas com erro — e veredito 'saudavel' na mesma linha. O numero estava
-- ali, contradizendo o veredito, e ninguem lia. Guarda que nao pode disparar e
-- pior que guarda que dispara demais: o vigia do banco roda a cada 30 minutos,
-- tem o token no cofre e o chat configurado — portanto TEM VOZ — e passou seis
-- dias calado, porque sua unica regra de fonte e `veredito in ('cega','muda')`.
--
-- POR QUE QUEDA DE LEITURA, E NAO TAXA DE FALHA: entre 05 e 08/11 metade das
-- rodadas ja vinha marcada 'parcial', mas a leitura caiu so 5% (2,5 palavras
-- de 20). Alarmar ali seria barulho. O que importa e capacidade perdida, e ela
-- se mede contra a propria linha de base da fonte. Com corte em 60% esta regra
-- fica calada em 05/11 (93% da base) e dispara em 09/11 (53%) — alarme no
-- dinheiro, nao no ruido. A erosao leve segue visivel no boletim, agora que os
-- coletores gravam `codigos_de_falha`.
--
-- 'degradada' entra DEPOIS de 'cega': parar de ler e pior que ler menos, e o
-- veredito pior tem que ganhar.
--
-- RODADA DE ENSAIO NAO CONTA. Os tres ensaios de diagnostico de hoje somaram
-- ~600 itens vistos na mesma hora e levaram leitura_vs_base de 0,39 para 0,65,
-- acima do corte: o ato de diagnosticar escondeu o problema do alarme. Medicao
-- que o proprio diagnostico altera nao serve. Rodada antiga da Shopee tem
-- metadados->>'ensaio' nulo porque o coletor so passou a gravar essa marca
-- agora; `is distinct from 'true'` trata nulo como producao, que e o certo
-- para o historico ja gravado.
--
-- No ledger do banco isto chegou em duas partes (20261111004225 e
-- 20261111004812); este arquivo e o estado final.
create or replace function public.saude_da_coleta()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_fonte_ml constant text := 'mercado_livre_api_oficial';
  v_ultima_rodada timestamptz;
  v_ultima_leitura timestamptz;
  v_minutos numeric;
  v_minutos_leitura numeric;
  v_veredito text;
  v_watchlist integer;
  v_leituras integer;
  v_revisita numeric;
  v_motivo text;
  v_por_fonte jsonb;
begin
  select max(e.iniciada_em) into v_ultima_rodada
  from public.execucoes e
  join public.fontes f on f.id = e.fonte_id
  where e.tipo = 'coleta' and f.slug = v_fonte_ml;

  select max(h.observado_em) into v_ultima_leitura
  from public.historico_precos h
  join public.ofertas o on o.id = h.oferta_id
  join public.fontes f on f.id = o.fonte_id
  where f.slug = v_fonte_ml;

  v_minutos := extract(epoch from (now() - v_ultima_rodada)) / 60.0;
  v_minutos_leitura := extract(epoch from (now() - v_ultima_leitura)) / 60.0;

  select e.metadados ->> 'motivo' into v_motivo
  from public.execucoes e
  join public.fontes f on f.id = e.fonte_id
  where e.tipo = 'coleta' and f.slug = v_fonte_ml
  order by e.iniciada_em desc
  limit 1;

  v_veredito := case
    when v_ultima_rodada is null then 'sem_registro'
    when v_minutos > 20 then 'muda'
    when v_minutos > 10 then 'atrasada'
    when v_ultima_leitura is null or v_minutos_leitura > 20 then 'cega'
    else 'saudavel'
  end;

  select count(*) into v_watchlist from public.itens_ml where habilitado;

  select count(*) into v_leituras
  from public.historico_precos h
  join public.ofertas o on o.id = h.oferta_id
  join public.fontes f on f.id = o.fonte_id
  where f.slug = v_fonte_ml
    and h.observado_em > now() - interval '1 hour';

  v_revisita := case when v_leituras > 0
                     then round(v_watchlist::numeric / v_leituras, 2)
                     end;

  select jsonb_object_agg(x.slug, jsonb_build_object(
           'rodadas_1h', x.rodadas_1h,
           'falhas_1h', x.falhas_1h,
           'leituras_1h', x.leituras_1h,
           'ultima_leitura_em', x.ultima_leitura,
           'minutos_desde_a_leitura', round(x.minutos_leitura, 1),
           'tolerancia_minutos', round(x.tolerancia, 1),
           'vistos_1h', x.vistos_1h,
           'vistos_base_7d', round(x.vistos_base, 0),
           'leitura_vs_base', case when x.vistos_base >= 100
                                   then round(x.vistos_1h / x.vistos_base, 2)
                              end,
           'codigos_de_falha_1h', x.codigos_de_falha,
           'veredito', case
             when x.rodadas_24h = 0 then 'sem_registro'
             when x.ultima_leitura is null then 'cega'
             when x.minutos_leitura > x.tolerancia then 'cega'
             -- Base pequena nao autoriza veredito: fonte recem-ligada ou de
             -- volume baixo oscila demais e viraria alarme falso.
             when x.vistos_base >= 100 and x.vistos_1h < x.vistos_base * 0.6
               then 'degradada'
             else 'saudavel'
           end
         ))
    into v_por_fonte
  from (
    select f.slug,
           (select count(*) from public.execucoes e
             where e.fonte_id = f.id and e.tipo = 'coleta'
               and e.metadados ->> 'ensaio' is distinct from 'true'
               and e.iniciada_em > now() - interval '1 hour') as rodadas_1h,
           (select count(*) from public.execucoes e
             where e.fonte_id = f.id and e.tipo = 'coleta'
               and e.metadados ->> 'ensaio' is distinct from 'true'
               and e.situacao in ('falhou', 'parcial')
               and e.iniciada_em > now() - interval '1 hour') as falhas_1h,
           r.rodadas_24h,
           (select count(*) from public.historico_precos h
              join public.ofertas o on o.id = h.oferta_id
             where o.fonte_id = f.id
               and h.observado_em > now() - interval '1 hour') as leituras_1h,
           u.ultima_leitura,
           extract(epoch from (now() - u.ultima_leitura)) / 60.0 as minutos_leitura,
           greatest(1440.0 / greatest(r.rodadas_24h, 1) * 3, 20) as tolerancia,
           coalesce(v.vistos_1h, 0)::numeric as vistos_1h,
           coalesce(b.vistos_base, 0)::numeric as vistos_base,
           c.codigos_de_falha
    from public.fontes f
    cross join lateral (
      select count(*) as rodadas_24h from public.execucoes e
      where e.fonte_id = f.id and e.tipo = 'coleta'
        and e.metadados ->> 'ensaio' is distinct from 'true'
        and e.iniciada_em > now() - interval '24 hours'
    ) r
    cross join lateral (
      select max(h.observado_em) as ultima_leitura
      from public.historico_precos h
      join public.ofertas o on o.id = h.oferta_id
      where o.fonte_id = f.id
    ) u
    cross join lateral (
      select sum(e.itens_vistos) as vistos_1h
      from public.execucoes e
      where e.fonte_id = f.id and e.tipo = 'coleta'
        and e.metadados ->> 'ensaio' is distinct from 'true'
        and e.iniciada_em > now() - interval '1 hour'
    ) v
    cross join lateral (
      -- Mediana horaria dos 7 dias ANTERIORES, excluindo a ultima hora: a hora
      -- que esta sendo julgada nao pode entrar na propria base.
      select percentile_cont(0.5) within group (order by h.vistos) as vistos_base
      from (
        select sum(e.itens_vistos) as vistos
        from public.execucoes e
        where e.fonte_id = f.id and e.tipo = 'coleta'
          and e.metadados ->> 'ensaio' is distinct from 'true'
          and e.iniciada_em between now() - interval '8 days' and now() - interval '1 hour'
        group by date_trunc('hour', e.iniciada_em)
      ) h
    ) b
    cross join lateral (
      select jsonb_object_agg(k.codigo, k.quantas) as codigos_de_falha
      from (
        select d.key as codigo, sum((d.value)::int) as quantas
        from public.execucoes e,
             lateral jsonb_each(coalesce(e.metadados -> 'codigos_de_falha', '{}'::jsonb)) d
        where e.fonte_id = f.id and e.tipo = 'coleta'
          and e.metadados ->> 'ensaio' is distinct from 'true'
          and e.iniciada_em > now() - interval '1 hour'
        group by d.key
      ) k
    ) c
    where f.habilitada
  ) x;

  return jsonb_build_object(
    'veredito', v_veredito,
    'motivo_da_cegueira', case when v_veredito = 'cega' then v_motivo end,
    'ultima_rodada_em', v_ultima_rodada,
    'minutos_desde_a_rodada', round(v_minutos, 1),
    'ultima_leitura_em', v_ultima_leitura,
    'minutos_desde_a_leitura', round(v_minutos_leitura, 1),
    'rodadas_1h', (
      select count(*) from public.execucoes e
      join public.fontes f on f.id = e.fonte_id
      where e.tipo = 'coleta' and f.slug = v_fonte_ml
        and e.iniciada_em > now() - interval '1 hour'
    ),
    'falhas_1h', (
      select count(*) from public.execucoes e
      join public.fontes f on f.id = e.fonte_id
      where e.tipo = 'coleta' and f.slug = v_fonte_ml
        and e.situacao in ('falhou', 'parcial')
        and e.iniciada_em > now() - interval '1 hour'
    ),
    'penduradas', (
      select count(*) from public.execucoes
      where situacao = 'rodando' and iniciada_em < now() - interval '15 minutes'
    ),
    'leituras_1h', v_leituras,
    'itens_na_watchlist', v_watchlist,
    'itens_sem_link', (
      select count(*) from public.itens_ml where habilitado and url_afiliado is null
    ),
    'revisita_horas', v_revisita,
    'revisita_veredito', case
      when v_revisita is null then 'sem_leitura'
      when v_revisita > 2 then 'esticada'
      else 'ok'
    end,
    'por_fonte', coalesce(v_por_fonte, '{}'::jsonb)
  );
end;
$function$;

-- A regra nova precisa chegar ao vigia. Funcao propria para poder ser testada
-- sozinha, no mesmo formato de entrega_por_fonte(): array de {chave, texto}.
create or replace function public.fontes_degradadas()
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'chave', 'degradada:' || d.slug,
           'texto', format(
             'LEITURA CAINDO: a fonte %s leu %s itens na ultima hora, %s%% do normal (base %s). Veredito degradada. Erros da ultima hora: %s. Menos leitura e menos chance de pegar queda de preco.',
             d.slug,
             d.vistos_1h,
             round(d.razao * 100),
             d.base,
             coalesce(d.codigos::text, 'nenhum registrado'))
         )), '[]'::jsonb)
  from (
    select key as slug,
           (value ->> 'vistos_1h')::numeric as vistos_1h,
           (value ->> 'vistos_base_7d')::numeric as base,
           (value ->> 'leitura_vs_base')::numeric as razao,
           value -> 'codigos_de_falha_1h' as codigos
    from jsonb_each(public.saude_da_coleta() -> 'por_fonte')
    where value ->> 'veredito' = 'degradada'
  ) d;
$function$;

revoke all on function public.fontes_degradadas() from public, anon;
grant execute on function public.fontes_degradadas() to service_role, authenticated;
