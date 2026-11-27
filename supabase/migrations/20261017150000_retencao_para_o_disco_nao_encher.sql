-- ---------------------------------------------------------------------------
-- Retencao: o motor parou em 16/10 07:24 UTC porque o DISCO ENCHEU.
--
-- O que aconteceu: o banco passou de 1.587 MB, o Supabase colocou o Postgres
-- em `default_transaction_read_only = on`, e toda rodada do pg_cron escreve.
-- Nada pode escrever -> nenhuma rodada roda -> o pg_cron nem consegue gravar
-- cron.job_run_details, por isso as rodadas nao aparecem como 'failed': elas
-- simplesmente desaparecem. 32h de silencio sem um unico erro registrado.
--
-- A causa raiz e minha: `rodar_faxina()` solta reserva vencida, cancela
-- aprovacao morta e encerra execucao orfa — mas NUNCA apara nenhuma das
-- quatro tabelas que crescem para sempre. Em 17/10 elas eram:
--
--   auditoria          1.021 MB   trilha de mudanca, nada no sistema le
--   historico_precos     496 MB   vantagem_de_preco() le so os ultimos 30 dias
--   execucoes             30 MB   registro de rodada
--   cron.job_run_details  14 MB   retencao propria do pg_cron desligada
--
-- 1.517 MB dos 1.587 MB em duas tabelas que ninguem consulta por inteiro.
-- Tudo que faz o trabalho — ofertas, fila, publicacoes — soma poucos MB.
--
-- POR QUE ESTES PRAZOS:
--   auditoria 14 dias  — e trilha de auditoria de tabela sensivel. Nenhuma
--     funcao do sistema le. Duas semanas bastam para investigar um incidente.
--   historico_precos 45 dias — vantagem_de_preco() agrega mediana por dia
--     dentro de uma janela de 30 dias e nunca olha mais para tras. 45 da 15
--     dias de margem, para que mexer na janela nunca morda a retencao.
--     NAO afino as leituras DENTRO da janela: a mediana do dia depende de
--     quantas leituras existem no dia, e mexer nisso mexe no sinal de preco,
--     que e o dinheiro. Uma mudanca por vez.
--   execucoes 30 dias — saude_da_coleta() olha a ultima; o boletim, 24h.
--   cron.job_run_details 7 dias — a consulta de rodadas perdidas usa 24h.
--
-- Apaga em lote para que uma rodada nunca segure lock por muito tempo: o
-- motor publica a cada 10 min e a faxina nao pode atravessar o caminho dele.
-- ---------------------------------------------------------------------------

create or replace function public.limpar_auditoria(p_dias integer default 14,
                                                   p_lote integer default 20000)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_removidas integer;
begin
  with vitimas as (
    select a.id
    from public.auditoria a
    where a.ocorrido_em < now() - make_interval(days => p_dias)
    order by a.id
    limit p_lote
  )
  delete from public.auditoria a
  using vitimas v
  where a.id = v.id;

  get diagnostics v_removidas = row_count;
  return v_removidas;
end;
$$;

revoke execute on function public.limpar_auditoria(integer, integer) from anon, authenticated, public;

comment on function public.limpar_auditoria(integer, integer) is
  'Apara a trilha de auditoria. Nenhuma funcao do sistema le auditoria; ela '
  'existe para investigar incidente. Sem isso a tabela chegou a 1.021 MB e '
  'encheu o disco, o que parou o motor por 32h em 16/10.';

-- ---------------------------------------------------------------------------

create or replace function public.limpar_historico_precos(p_dias integer default 45,
                                                          p_lote integer default 20000)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_removidas integer;
begin
  -- 45 dias e deliberadamente MAIOR que a janela de 30 dias que
  -- vantagem_de_preco() consulta. A margem de 15 dias existe para que
  -- ninguem precise lembrar de mexer aqui ao mexer na janela de la.
  with vitimas as (
    select h.id
    from public.historico_precos h
    where h.observado_em < now() - make_interval(days => p_dias)
    order by h.id
    limit p_lote
  )
  delete from public.historico_precos h
  using vitimas v
  where h.id = v.id;

  get diagnostics v_removidas = row_count;
  return v_removidas;
end;
$$;

revoke execute on function public.limpar_historico_precos(integer, integer) from anon, authenticated, public;

comment on function public.limpar_historico_precos(integer, integer) is
  'Apara leitura de preco antiga. vantagem_de_preco() agrega mediana por dia '
  'numa janela de 30 dias e nunca olha mais para tras, entao 45 dias e seguro '
  'com margem. Nao afina leitura DENTRO da janela: isso mudaria a mediana do '
  'dia e portanto o sinal de preco.';

-- ---------------------------------------------------------------------------

create or replace function public.limpar_registros_de_rodada(p_dias_execucoes integer default 30,
                                                             p_dias_cron integer default 7,
                                                             p_lote integer default 20000)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_execucoes integer;
  v_cron integer;
begin
  with vitimas as (
    select e.id
    from public.execucoes e
    where e.iniciada_em < now() - make_interval(days => p_dias_execucoes)
    order by e.id
    limit p_lote
  )
  delete from public.execucoes e
  using vitimas v
  where e.id = v.id;
  get diagnostics v_execucoes = row_count;

  -- cron.job_run_details nao tem retencao propria ligada. Sem aparar, ela
  -- cresce para sempre no mesmo disco.
  delete from cron.job_run_details
  where runid in (
    select runid
    from cron.job_run_details
    where start_time < now() - make_interval(days => p_dias_cron)
    order by runid
    limit p_lote
  );
  get diagnostics v_cron = row_count;

  return jsonb_build_object(
    'execucoes_removidas', v_execucoes,
    'rodadas_cron_removidas', v_cron
  );
end;
$$;

revoke execute on function public.limpar_registros_de_rodada(integer, integer, integer) from anon, authenticated, public;

comment on function public.limpar_registros_de_rodada(integer, integer, integer) is
  'Apara execucoes e cron.job_run_details. saude_da_coleta() olha a ultima '
  'execucao e o boletim olha 24h; a consulta de rodadas perdidas usa 24h.';

-- ---------------------------------------------------------------------------
-- A faxina passa a aparar o disco tambem.
--
-- Ela ja roda a cada 10 min (job baixou-faxina). Nao crio agenda nova: um
-- mecanismo que falha calado e o inimigo, e uma faxina que ja existe e nao
-- limpa a coisa que derruba o sistema e exatamente isso.
-- ---------------------------------------------------------------------------

create or replace function public.rodar_faxina()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_reservas integer;
  v_aprovacoes integer;
  v_orfas integer;
  v_auditoria integer;
  v_historico integer;
  v_rodadas jsonb;
begin
  select public.liberar_reservas_vencidas() into v_reservas;
  select public.cancelar_aprovacoes_vencidas() into v_aprovacoes;
  select public.encerrar_execucoes_orfas() into v_orfas;

  select public.limpar_auditoria() into v_auditoria;
  select public.limpar_historico_precos() into v_historico;
  select public.limpar_registros_de_rodada() into v_rodadas;

  return jsonb_build_object(
    'reservas_liberadas', v_reservas,
    'aprovacoes_canceladas', v_aprovacoes,
    'execucoes_orfas_encerradas', v_orfas,
    'auditoria_removidas', v_auditoria,
    'historico_removidas', v_historico,
    'rodadas_removidas', v_rodadas
  );
end;
$$;

comment on function public.rodar_faxina() is
  'Faxina de 10 em 10 min: solta reserva vencida, cancela aprovacao morta, '
  'encerra execucao orfa E apara as quatro tabelas que crescem para sempre. '
  'Sem a parte de aparar, o disco encheu em 16/10 e o motor ficou 32h parado.';

-- ---------------------------------------------------------------------------
-- Guarda: o boletim passa a enxergar o disco.
--
-- A cegueira de 16/10 nao foi so o disco encher — foi NINGUEM MEDIR o disco.
-- Um limite que nunca pode disparar e pior que um alarme que fala demais.
-- ---------------------------------------------------------------------------

create or replace function public.saude_do_disco()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_bytes bigint;
  v_somente_leitura boolean;
begin
  select pg_database_size(current_database()) into v_bytes;
  select current_setting('default_transaction_read_only') = 'on' into v_somente_leitura;

  return jsonb_build_object(
    'tamanho', pg_size_pretty(v_bytes),
    'bytes', v_bytes,
    'somente_leitura', v_somente_leitura,
    'veredito', case
      when v_somente_leitura then 'travado'
      when v_bytes > 900 * 1024 * 1024 then 'perto_do_limite'
      else 'ok'
    end,
    'maiores', (
      select coalesce(jsonb_agg(jsonb_build_object('tabela', t.tabela, 'tamanho', t.tamanho)
                                order by t.bytes desc), '[]'::jsonb)
      from (
        select c.relname as tabela,
               pg_size_pretty(pg_total_relation_size(c.oid)) as tamanho,
               pg_total_relation_size(c.oid) as bytes
        from pg_class c
        join pg_namespace ns on ns.oid = c.relnamespace
        where ns.nspname in ('public', 'cron')
          and c.relkind = 'r'
        order by pg_total_relation_size(c.oid) desc
        limit 5
      ) t
    )
  );
end;
$$;

revoke execute on function public.saude_do_disco() from anon, authenticated, public;

comment on function public.saude_do_disco() is
  'Diz se o disco esta perto de travar o motor. veredito travado significa '
  'que o Postgres ja esta somente-leitura: nenhuma rodada escreve, nenhuma '
  'rodada aparece como falha, e o motor morre em silencio.';
