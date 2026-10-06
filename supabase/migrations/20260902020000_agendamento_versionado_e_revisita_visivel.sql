-- O agendamento volta para o repositorio, e a revisita deixa de ser invisivel
--
-- A migracao 20260826 afirma no proprio comentario que o cron do coletor foi
-- de */5 para */2 "aplicados com cron.alter_job nos jobs 1 e 4". O arquivo nao
-- contem nenhum alter_job. Foi feito a mao, e a mao saiu */3.
--
-- O custo nao foi teorico: */3 da 20 rodadas por hora em vez de 30, ou seja
-- 200 leituras/h no lugar das 300 que a propria migracao dimensionou. Um terco
-- da vigilancia desapareceu sem nenhum alarme tocar, porque nada no sistema
-- olha para esse numero.
--
-- Terceira vez que repo e banco divergem. Nas duas primeiras o custo foi meu
-- tempo; nesta foi um terco da capacidade de pegar oferta, por uma semana.
--
-- Entao aqui o agendamento vira codigo declarado, e nao instrucao em prosa
-- dentro de um comentario. cron.schedule no pg_cron 1.6 casa pelo nome do job:
-- rodar isto conserta a agenda de quem estiver errada e nao duplica nada.

-- ---------------------------------------------------------------------------
-- Os quatro jobs, declarados
--
--   coletor    */2  - 30 rodadas/h x 10 itens = 300 leituras/h. E o que
--                     sustenta a revisita dimensionada em 20260826.
--   worker     */2  - publica no maximo um item, e so quando as porteiras
--                     deixam.
--   faxina    */10  - solta reserva vencida e cancela aprovacao morta.
--   descoberta */20 - cadastra produto novo. Fica DESLIGADA (veja abaixo).
-- ---------------------------------------------------------------------------

select cron.schedule('baixou-coletor-ml', '*/2 * * * *',  $$select public.disparar_coletor_ml()$$);
select cron.schedule('baixou-worker',     '*/2 * * * *',  $$select public.disparar_worker()$$);
select cron.schedule('baixou-faxina',     '*/10 * * * *', $$select public.rodar_faxina()$$);
select cron.schedule('baixou-descoberta', '*/20 * * * *', $$select public.rodar_descoberta()$$);

-- A descoberta esta desligada no banco desde 01/09. Nao sei se foi decisao ou
-- descuido, e cron.schedule reativa qualquer job que ele toca — entao aqui ela
-- e explicitamente devolvida ao estado em que estava.
--
-- Religar e uma linha (`select cron.alter_job(4, active => true)`), mas e
-- decisao de quem toca o projeto: descoberta ligada aumenta a carga no ML, e
-- isso se pesa com o aviso do ML na mesa, nao por conta de uma migracao.
select cron.alter_job(
  (select jobid from cron.job where jobname = 'baixou-descoberta'),
  active => false
);

-- ---------------------------------------------------------------------------
-- A revisita passa a aparecer
--
-- Revisita e o intervalo medio entre duas leituras do mesmo item:
-- watchlist / leituras por hora. E o numero que decide se queda relampago e
-- pega — o README ja dizia isso — e mesmo assim era o unico numero importante
-- que ninguem media. Foi por isso que */3 passou uma semana despercebido.
--
-- Ela degrada de dois jeitos, e os dois sao silenciosos: a watchlist cresce
-- (numerador sobe) ou a vazao cai (denominador desce). Nos dois casos o
-- veredito continua dizendo "saudavel", porque o coletor de fato esta rodando.
--
-- Por isso vai em campo proprio, e nao dentro do veredito. Sao perguntas
-- diferentes: `veredito` responde "o coletor esta vivo?", `revisita_veredito`
-- responde "ele esta acompanhando o tamanho da base?". Coletor que roda e nao
-- da conta e uma falha distinta de coletor que nao roda, do mesmo jeito que
-- rodada e leitura ja sao contadas separadamente aqui.
--
-- O corte em 2h e a margem sobre as ~1h40 que 20260826 dimensionou.
-- ---------------------------------------------------------------------------

create or replace function public.saude_da_coleta()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_ultima_rodada timestamptz;
  v_ultima_leitura timestamptz;
  v_minutos numeric;
  v_veredito text;
  v_watchlist integer;
  v_leituras integer;
  v_revisita numeric;
begin
  select max(e.iniciada_em) into v_ultima_rodada
  from public.execucoes e where e.tipo = 'coleta';

  select max(h.observado_em) into v_ultima_leitura from public.historico_precos h;

  v_minutos := extract(epoch from (now() - v_ultima_rodada)) / 60.0;

  v_veredito := case
    when v_ultima_rodada is null then 'sem_registro'
    when v_minutos > 20 then 'muda'
    when v_minutos > 10 then 'atrasada'
    else 'saudavel'
  end;

  select count(*) into v_watchlist from public.itens_ml where habilitado;

  select count(*) into v_leituras from public.historico_precos
  where observado_em > now() - interval '1 hour';

  -- Sem leitura na ultima hora nao da para estimar revisita. Devolve null em
  -- vez de dividir por zero ou fingir um numero: quem le precisa distinguir
  -- "esticada" de "nao sei".
  v_revisita := case when v_leituras > 0
                     then round(v_watchlist::numeric / v_leituras, 2)
                     end;

  return jsonb_build_object(
    'veredito', v_veredito,
    'ultima_rodada_em', v_ultima_rodada,
    'minutos_desde_a_rodada', round(v_minutos, 1),
    'ultima_leitura_em', v_ultima_leitura,
    'minutos_desde_a_leitura',
      round(extract(epoch from (now() - v_ultima_leitura)) / 60.0, 1),
    'rodadas_1h', (
      select count(*) from public.execucoes
      where tipo = 'coleta' and iniciada_em > now() - interval '1 hour'
    ),
    'falhas_1h', (
      select count(*) from public.execucoes
      where tipo = 'coleta' and situacao in ('falhou', 'parcial')
        and iniciada_em > now() - interval '1 hour'
    ),
    'penduradas', (
      select count(*) from public.execucoes
      where situacao = 'rodando' and iniciada_em < now() - interval '15 minutes'
    ),
    'leituras_1h', v_leituras,
    'itens_na_watchlist', v_watchlist,
    -- Quantos nao podem virar comissao. Se este numero cresce, a descoberta
    -- esta correndo mais rapido do que os links sao gerados.
    'itens_sem_link', (
      select count(*) from public.itens_ml where habilitado and url_afiliado is null
    ),
    -- Horas entre duas leituras do mesmo item.
    'revisita_horas', v_revisita,
    'revisita_veredito', case
      when v_revisita is null then 'sem_leitura'
      when v_revisita > 2 then 'esticada'
      else 'ok'
    end
  );
end;
$$;

revoke all on function public.saude_da_coleta() from public, anon;
grant execute on function public.saude_da_coleta() to service_role, authenticated;
