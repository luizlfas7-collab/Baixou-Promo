-- saude_da_coleta() passa a enxergar cada fonte.
--
-- O PROBLEMA, e ele e de alarme, nao de metrica:
--
--   select max(h.observado_em) into v_ultima_leitura from public.historico_precos h;
--
-- Esse max varre TODAS as fontes. O veredito 'cega' — construido depois das
-- 62h em que o ML ficou mudo e ninguem viu — dispara quando a ultima leitura
-- passa de 20 minutos. Com a Shopee gravando de 16 em 16 minutos, o ML pode
-- morrer AGORA que esse campo continua fresco e a funcao responde 'saudavel'.
-- A segunda fonte desarmou o alarme da primeira.
--
-- E a revisita mentia junto:
--
--   v_watchlist := (itens_ml habilitados)          -- 320, so ML
--   v_leituras  := (historico_precos na ultima hora) -- 841, ML + Shopee
--   v_revisita  := v_watchlist / v_leituras         -- 0,38h
--
-- Numerador de uma fonte, denominador de duas. A revisita real do ML e
-- 320 / 299 = 1,07h. A funcao reportava 0,38h — 2,8x otimista — e ficava MAIS
-- otimista a cada item que a Shopee ganhasse. Justamente o numero que existe
-- para avisar que o motor nao acompanha o tamanho da base.
--
-- `rodadas_1h` e `falhas_1h` tinham o mesmo defeito: somavam as duas fontes,
-- entao uma Shopee saudavel diluia falha do ML.
--
-- O QUE MUDA:
--
--   1. Os campos do topo passam a ser do MERCADO LIVRE, que e a fonte de quem
--      `itens_na_watchlist` sempre falou. Mesmas chaves, mesmo formato — a
--      rotina de vigilancia continua funcionando — mas agora verdadeiros.
--
--   2. Entra `por_fonte`: cada fonte com as proprias rodadas, leituras,
--      minutos desde a ultima leitura e veredito proprio.
--
--   3. A tolerancia de cada fonte se calibra sozinha pela cadencia observada
--      nas ultimas 24h, com piso de 20 minutos. O ML roda a cada 2 minutos e
--      a Shopee a cada 16; uma tolerancia fixa culparia a Shopee de atraso ou
--      perdoaria o ML por meia hora de silencio.
--
-- O veredito do topo passa a ser 'cega' quando o ML para de ler, mesmo com a
-- Shopee a todo vapor. Que e o ponto.

create or replace function public.saude_da_coleta()
returns jsonb
language plpgsql
security definer
set search_path = ''
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
  -- Daqui para baixo, TUDO do topo e Mercado Livre. `itens_na_watchlist`
  -- sempre foi so dele; o resto agora combina.
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

  -- Uma linha por fonte habilitada, com tolerancia calibrada pela propria
  -- cadencia: o ML roda de 2 em 2 minutos, a Shopee de 16 em 16. Numero fixo
  -- acusaria a Shopee de atraso ou perdoaria meia hora de silencio do ML.
  select jsonb_object_agg(x.slug, jsonb_build_object(
           'rodadas_1h', x.rodadas_1h,
           'falhas_1h', x.falhas_1h,
           'leituras_1h', x.leituras_1h,
           'ultima_leitura_em', x.ultima_leitura,
           'minutos_desde_a_leitura', round(x.minutos_leitura, 1),
           'tolerancia_minutos', round(x.tolerancia, 1),
           'veredito', case
             when x.rodadas_24h = 0 then 'sem_registro'
             when x.ultima_leitura is null then 'cega'
             when x.minutos_leitura > x.tolerancia then 'cega'
             else 'saudavel'
           end
         ))
    into v_por_fonte
  from (
    select f.slug,
           (select count(*) from public.execucoes e
             where e.fonte_id = f.id and e.tipo = 'coleta'
               and e.iniciada_em > now() - interval '1 hour') as rodadas_1h,
           (select count(*) from public.execucoes e
             where e.fonte_id = f.id and e.tipo = 'coleta'
               and e.situacao in ('falhou', 'parcial')
               and e.iniciada_em > now() - interval '1 hour') as falhas_1h,
           r.rodadas_24h,
           (select count(*) from public.historico_precos h
              join public.ofertas o on o.id = h.oferta_id
             where o.fonte_id = f.id
               and h.observado_em > now() - interval '1 hour') as leituras_1h,
           u.ultima_leitura,
           extract(epoch from (now() - u.ultima_leitura)) / 60.0 as minutos_leitura,
           -- tres intervalos esperados, nunca menos de 20 minutos
           greatest(1440.0 / greatest(r.rodadas_24h, 1) * 3, 20) as tolerancia
    from public.fontes f
    cross join lateral (
      select count(*) as rodadas_24h from public.execucoes e
      where e.fonte_id = f.id and e.tipo = 'coleta'
        and e.iniciada_em > now() - interval '24 hours'
    ) r
    cross join lateral (
      select max(h.observado_em) as ultima_leitura
      from public.historico_precos h
      join public.ofertas o on o.id = h.oferta_id
      where o.fonte_id = f.id
    ) u
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
    -- Penduradas segue global de proposito: execucao travada e travada,
    -- independente de quem a abriu.
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
