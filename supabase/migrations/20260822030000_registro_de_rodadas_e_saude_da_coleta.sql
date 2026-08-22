-- Registro de rodadas e saude da coleta
--
-- A tabela public.execucoes existe desde 16/08 e nunca recebeu uma linha.
-- Coletor e worker rodavam sem deixar rastro: um dia em que o coletor parasse
-- ficaria identico a um dia sem queda de preco. E o mesmo silencio que segurou
-- o Radar Rota por 34 dias — nao houve alarme porque nao havia o que alarmar.
--
-- Aqui entram as duas pontas do registro (abrir / fechar), o encerramento de
-- rodadas orfas e a pergunta que interessa: a coleta esta viva?

-- ---------------------------------------------------------------------------
-- Abrir
-- ---------------------------------------------------------------------------

create or replace function public.execucao_abrir(
  p_chave text,
  p_tipo text,
  p_worker text default null,
  p_fonte_slug text default null
)
returns bigint
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_id bigint;
  v_fonte_id bigint;
begin
  if p_fonte_slug is not null then
    select f.id into v_fonte_id
    from public.fontes f
    where f.slug = p_fonte_slug;
  end if;

  insert into public.execucoes (chave_execucao, tipo, situacao, identificador_worker, fonte_id)
  values (p_chave, p_tipo, 'rodando', p_worker, v_fonte_id)
  on conflict (chave_execucao) do nothing
  returning id into v_id;

  -- Chave repetida significa retentativa do mesmo disparo, nao rodada nova.
  -- Devolver o id existente mantem o registro unico em vez de duplicar.
  if v_id is null then
    select e.id into v_id
    from public.execucoes e
    where e.chave_execucao = p_chave;
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Fechar
-- ---------------------------------------------------------------------------

create or replace function public.execucao_fechar(
  p_id bigint,
  p_situacao text,
  p_vistos integer default 0,
  p_inseridos integer default 0,
  p_atualizados integer default 0,
  p_recusados integer default 0,
  p_enfileirados integer default 0,
  p_publicados integer default 0,
  p_resumo_erro text default null,
  p_metadados jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  update public.execucoes
  set situacao = p_situacao,
      encerrada_em = now(),
      itens_vistos = coalesce(p_vistos, 0),
      itens_inseridos = coalesce(p_inseridos, 0),
      itens_atualizados = coalesce(p_atualizados, 0),
      itens_recusados = coalesce(p_recusados, 0),
      itens_enfileirados = coalesce(p_enfileirados, 0),
      itens_publicados = coalesce(p_publicados, 0),
      resumo_erro = left(p_resumo_erro, 2000),
      metadados = coalesce(p_metadados, '{}'::jsonb)
  where id = p_id
    and encerrada_em is null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Rodadas orfas
--
-- Processo que morre no meio deixa a linha em 'rodando' para sempre. Sem isso,
-- 'rodadas penduradas' cresceria sem parar e a saude ficaria vermelha por
-- historia antiga em vez de problema atual.
-- ---------------------------------------------------------------------------

create or replace function public.encerrar_execucoes_orfas(p_limite_minutos integer default 15)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_total integer;
begin
  with orfas as (
    update public.execucoes
    set situacao = 'falhou',
        encerrada_em = now(),
        resumo_erro = coalesce(
          resumo_erro,
          'Rodada nao encerrada dentro de ' || p_limite_minutos || ' minutos.'
        )
    where situacao = 'rodando'
      and iniciada_em < now() - make_interval(mins => p_limite_minutos)
    returning 1
  )
  select count(*) into v_total from orfas;

  return v_total;
end;
$$;

-- ---------------------------------------------------------------------------
-- Faxina passa a encerrar orfas tambem
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
begin
  select public.liberar_reservas_vencidas() into v_reservas;
  select public.cancelar_aprovacoes_vencidas() into v_aprovacoes;
  select public.encerrar_execucoes_orfas() into v_orfas;

  return jsonb_build_object(
    'reservas_liberadas', v_reservas,
    'aprovacoes_canceladas', v_aprovacoes,
    'execucoes_orfas_encerradas', v_orfas
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Saude da coleta
--
-- Responde a unica pergunta que importa de madrugada: ela esta viva? Cruza
-- rodada com leitura de preco de proposito — coletor que roda e nao le e uma
-- falha diferente de coletor que nao roda, e as duas precisam aparecer.
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
begin
  select max(e.iniciada_em) into v_ultima_rodada
  from public.execucoes e
  where e.tipo = 'coleta';

  select max(h.observado_em) into v_ultima_leitura
  from public.historico_precos h;

  v_minutos := extract(epoch from (now() - v_ultima_rodada)) / 60.0;

  v_veredito := case
    when v_ultima_rodada is null then 'sem_registro'
    when v_minutos > 20 then 'muda'
    when v_minutos > 10 then 'atrasada'
    else 'saudavel'
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
    'leituras_1h', (
      select count(*) from public.historico_precos
      where observado_em > now() - interval '1 hour'
    ),
    'itens_na_watchlist', (
      select count(*) from public.itens_ml where habilitado
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissoes
-- ---------------------------------------------------------------------------

revoke all on function public.execucao_abrir(text, text, text, text) from public, anon, authenticated;
revoke all on function public.execucao_fechar(bigint, text, integer, integer, integer, integer, integer, integer, text, jsonb) from public, anon, authenticated;
revoke all on function public.encerrar_execucoes_orfas(integer) from public, anon, authenticated;
revoke all on function public.saude_da_coleta() from public, anon;

grant execute on function public.execucao_abrir(text, text, text, text) to service_role;
grant execute on function public.execucao_fechar(bigint, text, integer, integer, integer, integer, integer, integer, text, jsonb) to service_role;
grant execute on function public.encerrar_execucoes_orfas(integer) to service_role;
grant execute on function public.saude_da_coleta() to service_role, authenticated;

comment on function public.saude_da_coleta() is
  'A coleta esta viva? Cruza rodada com leitura de preco. Veredito: saudavel, atrasada, muda, sem_registro.';
