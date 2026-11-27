-- A BASE DO ALARME DE DEGRADACAO ERA DEFEITUOSA POR CONSTRUCAO.
--
-- Em 11/11 eu coloquei no ar o veredito 'degradada': dispara quando a fonte le
-- menos de 60% do normal dela. O "normal" era a MEDIANA HORARIA DOS 7 DIAS
-- ANTERIORES. Media movel. Quando a degradacao dura mais que a janela, a base
-- afunda junto com a leitura e a razao volta para perto de 1 — o alarme se
-- apaga sozinho exatamente quando o problema se torna permanente.
--
-- MEDIDO, e por isso este arquivo existe (eu mesmo reportei o defeito duas
-- vezes antes de corrigi-lo):
--   base movel em 11/11: 2290   |  14/11: 1290  |  15/11: 870
--   razao no mesmo periodo:     0,65  ->  0,67  ->  0,72   (SUBINDO)
-- A leitura real estava CAINDO e a razao SUBIA. Depois distorceu para o outro
-- lado: na recuperacao marcou 2,44 e 2,14, como se a fonte lesse o dobro do
-- normal, quando lia 78% do normal historico.
--
-- Hoje, 23/11, o boletim da manha disse "leitura_vs_base 1.09, 9% acima da
-- base" com a Shopee lendo 1740 itens/hora. O normal medido dela e 2400. A
-- leitura real era 72%. O numero que eu reportei ao dono estava errado, e
-- errado na direcao perigosa: tranquilizando.
--
-- A CORRECAO: ancora fixa, numa tabela, com a janela em que foi medida
-- gravada ao lado. Numero que nao se mexe sozinho nao pode afundar junto com
-- a queda. Quando a capacidade da fonte mudar de verdade (palavras-chave
-- novas, outra loja, outro teto por rodada), a ancora se atualiza de
-- proposito, com uma migracao, e nao calada.
--
-- MEDICAO DA ANCORA — janela 25/10 00:00 a 04/11 24:00 UTC, 264 horas cheias,
-- que e o periodo ANTES do "error [10000]" da Shopee comecar em 05/11:
--   shopee_open_api   mediana 2400/h, p25 2400, minimo 1800, maximo 2400
--   mercado_livre     mediana  300/h, p25  300, minimo  300, maximo  300
-- Os dois sao o proprio teto de capacidade: Shopee 4 rodadas x 20 palavras x
-- 30 itens = 2400; ML 300 = a watchlist inteira por hora.
--
-- VALIDACAO CONTRA O HISTORICO (dia a dia, 32 dias, mediana horaria do dia
-- contra a ancora 2400, corte em 0,6 -> dispara abaixo de 1440):
--   25/10 a 04/11  ->  1,00         calado      (periodo saudavel)
--   05/11 a 08/11  ->  0,93 a 0,94  calado      (erosao leve: ruido, nao alarme)
--   09/11 a 16/11  ->  0,29 a 0,38  DISPARA     oito dias seguidos
--   17/11 a 23/11  ->  0,69 a 0,76  calado      (recuperacao parcial)
-- Os oito dias em que o alarme ficou mudo na vida real sao exatamente os oito
-- dias em que a regra nova grita. E ela nao grita nos dias bons nem na erosao
-- leve. O corte de 0,6 NAO muda nesta migracao: uma coisa por vez, e o que
-- estava errado era a base, nao o corte.
--
-- A EROSAO QUE SOBRA FICA VISIVEL SEM ALARMAR. A Shopee hoje le 70-76% do
-- normal. Isso e perda real de capacidade e aparece em todo boletim agora que
-- a razao e honesta, mas nao e colapso e nao vira alarme a cada 6h. Alarme que
-- dispara sempre e barulho; guarda que nao pode disparar e pior. A divisao e
-- essa: alarme para colapso, boletim para erosao.
--
-- A chave exposta muda de nome de proposito: `vistos_base_7d` passou a mentir
-- no instante em que deixou de ser uma mediana de 7 dias. Vira `vistos_base`,
-- com `base_origem` ao lado dizendo de onde o numero veio. Guarda cuja
-- procedencia e invisivel foi o que me custou os seis dias de 11/11.

create table if not exists public.referencia_de_leitura (
  fonte_id        bigint primary key references public.fontes(id) on delete cascade,
  vistos_por_hora numeric not null check (vistos_por_hora > 0),
  medido_de       timestamptz not null,
  medido_ate      timestamptz not null,
  horas_medidas   integer not null check (horas_medidas > 0),
  anotacao        text not null,
  atualizado_em   timestamptz not null default now(),
  constraint referencia_janela_valida check (medido_ate > medido_de)
);

comment on table public.referencia_de_leitura is
  'Ancora fixa de leitura normal por fonte, em itens vistos por hora. Usada por saude_da_coleta() para julgar degradacao. NAO e recalculada automaticamente: media movel afunda junto com a queda e apaga o proprio alarme. Mudar so com migracao, atualizando medido_de/medido_ate/anotacao junto.';

alter table public.referencia_de_leitura enable row level security;
revoke all on table public.referencia_de_leitura from anon, authenticated;
grant all on table public.referencia_de_leitura to service_role;

insert into public.referencia_de_leitura
  (fonte_id, vistos_por_hora, medido_de, medido_ate, horas_medidas, anotacao)
select f.id, v.vistos,
       '2026-10-25 00:00:00+00'::timestamptz,
       '2026-11-05 00:00:00+00'::timestamptz,
       264, v.nota
from (values
  ('mercado_livre_api_oficial', 300::numeric,
   'Mediana horaria 300 em 264h (25/10-04/11). p25 300, minimo 300, maximo 300: totalmente plano. E a watchlist inteira lida por hora, 30 rodadas de 10 itens.'),
  ('shopee_open_api', 2400::numeric,
   'Mediana horaria 2400 em 264h (25/10-04/11), antes do error [10000] comecar em 05/11. p25 2400, minimo 1800, maximo 2400. E o teto: 4 rodadas/h x 20 palavras x 30 itens.')
) as v(slug, vistos, nota)
join public.fontes f on f.slug = v.slug
on conflict (fonte_id) do nothing;

-- saude_da_coleta(): identica ao que estava no banco, com UMA mudanca de
-- substancia — a lateral `b`, que calculava a mediana movel, agora prefere a
-- ancora fixa e so cai na mediana movel se a fonte nao tiver ancora medida.
-- Mais a renomeacao da chave e o `base_origem` ao lado dela.
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
           'vistos_base', round(x.vistos_base, 0),
           'base_origem', x.base_origem,
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
           b.base_origem,
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
      -- ANCORA FIXA primeiro. A mediana movel de 8 dias fica como ultimo
      -- recurso, para fonte recem-ligada que ainda nao tem ancora medida:
      -- base ruim e melhor que base nenhuma, DESDE QUE o boletim diga qual
      -- das duas esta em uso — e por isso `base_origem` sai ao lado.
      select coalesce(
               (select r2.vistos_por_hora
                  from public.referencia_de_leitura r2
                 where r2.fonte_id = f.id),
               m.movel::numeric
             ) as vistos_base,
             case when exists (select 1 from public.referencia_de_leitura r3
                                where r3.fonte_id = f.id)
                  then 'ancora_fixa'
                  else 'mediana_movel_7d'
             end as base_origem
      from (
        select percentile_cont(0.5) within group (order by h.vistos) as movel
        from (
          select sum(e.itens_vistos) as vistos
          from public.execucoes e
          where e.fonte_id = f.id and e.tipo = 'coleta'
            and e.metadados ->> 'ensaio' is distinct from 'true'
            and e.iniciada_em between now() - interval '8 days' and now() - interval '1 hour'
          group by date_trunc('hour', e.iniciada_em)
        ) h
      ) m
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

-- fontes_degradadas(): le a chave nova e diz de onde veio a base. Se o alarme
-- disparar com base_origem = mediana_movel_7d, o numero e suspeito e o texto
-- avisa, em vez de me deixar descobrir isso depois.
create or replace function public.fontes_degradadas()
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'chave', 'degradada:' || d.slug,
           'texto', format(
             'LEITURA CAINDO: a fonte %s leu %s itens na ultima hora, %s%% do normal (base %s, origem %s). Veredito degradada. Erros da ultima hora: %s. Menos leitura e menos chance de pegar queda de preco.',
             d.slug,
             d.vistos_1h,
             round(d.razao * 100),
             d.base,
             d.origem,
             coalesce(d.codigos::text, 'nenhum registrado'))
         )), '[]'::jsonb)
  from (
    select key as slug,
           (value ->> 'vistos_1h')::numeric as vistos_1h,
           (value ->> 'vistos_base')::numeric as base,
           (value ->> 'base_origem') as origem,
           (value ->> 'leitura_vs_base')::numeric as razao,
           value -> 'codigos_de_falha_1h' as codigos
    from jsonb_each(public.saude_da_coleta() -> 'por_fonte')
    where value ->> 'veredito' = 'degradada'
  ) d;
$function$;

revoke all on function public.saude_da_coleta() from public, anon;
grant execute on function public.saude_da_coleta() to service_role, authenticated;
revoke all on function public.fontes_degradadas() from public, anon;
grant execute on function public.fontes_degradadas() to service_role, authenticated;
