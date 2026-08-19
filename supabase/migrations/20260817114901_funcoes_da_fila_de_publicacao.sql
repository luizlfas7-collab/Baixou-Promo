-- ---------------------------------------------------------------------------
-- reservar_item_da_fila: aplica TODAS as porteiras e entrega no maximo um
-- item por destino. Roda inteiro dentro de uma transacao, com advisory lock
-- por destino, de modo que dois workers simultaneos nunca pegam o mesmo canal.
-- ---------------------------------------------------------------------------
create function public.reservar_item_da_fila(
  p_worker text,
  p_lote smallint default null
)
returns table (
  fila_id bigint,
  canal text,
  destino text,
  payload jsonb,
  token_reserva uuid,
  raia text,
  tentativas smallint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cfg public.configuracoes;
  v_agora timestamptz := now();
  v_hora_local time;
  v_lote smallint;
  v_item record;
  v_token uuid;
  v_expira timestamptz;
  v_ultimo timestamptz;
  v_na_hora integer;
  v_no_dia integer;
  v_reservados smallint := 0;
begin
  select * into v_cfg from public.configuracoes where id = 1 for update;

  if not found or v_cfg.trava_emergencia or not v_cfg.automacao_ativa then
    return;
  end if;

  if v_cfg.respeitar_janela then
    v_hora_local := (v_agora at time zone v_cfg.fuso)::time;
    if v_hora_local < v_cfg.janela_inicio or v_hora_local > v_cfg.janela_fim then
      return;
    end if;
  end if;

  v_lote := least(coalesce(p_lote, v_cfg.max_lote_reserva), v_cfg.max_lote_reserva);

  for v_item in
    select f.id, f.canal, f.destino, f.payload, f.raia, f.tentativas, f.aprovacao_id, f.oferta_id
    from public.fila_publicacao f
    join public.aprovacoes a on a.id = f.aprovacao_id
    join public.ofertas o on o.id = f.oferta_id
    join public.fontes fo on fo.id = o.fonte_id
    where f.situacao in ('pendente', 'retentar')
      and f.agendada_para <= v_agora
      and (f.proxima_tentativa_em is null or f.proxima_tentativa_em <= v_agora)
      -- A aprovacao precisa continuar valendo, agora.
      and a.decisao = 'aprovada'
      and a.vigente
      and (a.expira_em is null or a.expira_em > v_agora)
      -- A oferta precisa continuar elegivel e a fonte ligada.
      and o.situacao = 'elegivel'
      and o.disponivel
      and (o.expira_em is null or o.expira_em > v_agora)
      and fo.habilitada
    order by f.prioridade desc, f.agendada_para, f.id
    for update of f skip locked
  loop
    exit when v_reservados >= v_lote;

    -- Serializa por destino. Se outro worker esta no mesmo canal, pula.
    if not pg_try_advisory_xact_lock(hashtextextended(v_item.canal || ':' || v_item.destino, 0)) then
      continue;
    end if;

    -- Destino ocupado ou em quarentena.
    if exists (
      select 1 from public.estado_destino e
      where e.canal = v_item.canal
        and e.destino = v_item.destino
        and (e.quarentena_em is not null or (e.reservado_ate is not null and e.reservado_ate > v_agora))
    ) then
      continue;
    end if;

    select e.publicado_em into v_ultimo
    from public.estado_destino e
    where e.canal = v_item.canal and e.destino = v_item.destino;

    -- Intervalo minimo entre posts.
    if v_ultimo is not null
       and v_ultimo > v_agora - make_interval(secs => v_cfg.intervalo_minimo_segundos) then
      continue;
    end if;

    select count(*) into v_na_hora
    from public.publicacoes p
    where p.canal = v_item.canal and p.destino = v_item.destino
      and p.publicado_em > v_agora - interval '1 hour';

    if v_na_hora >= v_cfg.max_publicacoes_por_hora then
      continue;
    end if;

    select count(*) into v_no_dia
    from public.publicacoes p
    where p.canal = v_item.canal and p.destino = v_item.destino
      and p.publicado_em >= date_trunc('day', v_agora at time zone v_cfg.fuso) at time zone v_cfg.fuso;

    if v_no_dia >= v_cfg.max_publicacoes_por_dia then
      continue;
    end if;

    v_token := gen_random_uuid();
    v_expira := v_agora + make_interval(secs => v_cfg.ttl_reserva_segundos);

    update public.fila_publicacao f
      set situacao = 'reservada',
          reservada_por = p_worker,
          token_reserva = v_token,
          reservada_em = v_agora,
          reserva_expira_em = v_expira
      where f.id = v_item.id;

    insert into public.estado_destino (canal, destino, fila_reservada_id, reservado_ate)
    values (v_item.canal, v_item.destino, v_item.id, v_expira)
    on conflict (canal, destino) do update
      set fila_reservada_id = excluded.fila_reservada_id,
          reservado_ate = excluded.reservado_ate;

    v_reservados := v_reservados + 1;

    fila_id := v_item.id;
    canal := v_item.canal;
    destino := v_item.destino;
    payload := v_item.payload;
    token_reserva := v_token;
    raia := v_item.raia;
    tentativas := v_item.tentativas;
    return next;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- marcar_despacho_iniciado: o ponto de nao retorno. Refaz TODAS as checagens
-- sob o mesmo lock, imediatamente antes do envio HTTP. Repetir a mesma chave
-- de despacho poe o destino em quarentena, porque o provedor pode ter
-- aceitado a primeira tentativa.
-- ---------------------------------------------------------------------------
create function public.marcar_despacho_iniciado(
  p_fila_id bigint,
  p_token_reserva uuid,
  p_chave_despacho text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.fila_publicacao;
  v_agora timestamptz := now();
begin
  select * into v_item from public.fila_publicacao where id = p_fila_id for update;

  if not found then
    raise exception 'Item de fila % nao encontrado', p_fila_id using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_item.canal || ':' || v_item.destino, 0));

  -- Reuso de chave de despacho: resultado desconhecido, quarentena.
  if v_item.chave_despacho is not null and v_item.chave_despacho = p_chave_despacho then
    perform public.poe_destino_em_quarentena(
      v_item.canal, v_item.destino, v_item.id,
      'Chave de despacho reutilizada: o envio anterior pode ter sido aceito'
    );
    return false;
  end if;

  if v_item.situacao <> 'reservada' or v_item.token_reserva is distinct from p_token_reserva then
    return false;
  end if;

  if v_item.reserva_expira_em <= v_agora then
    return false;
  end if;

  -- A aprovacao e a oferta ainda precisam valer neste instante.
  if not exists (
    select 1
    from public.aprovacoes a
    join public.ofertas o on o.id = a.oferta_id
    where a.id = v_item.aprovacao_id
      and a.decisao = 'aprovada'
      and a.vigente
      and a.hash_conteudo_oferta = v_item.hash_conteudo_oferta
      and a.hash_payload_aprovado = v_item.hash_payload
      and (a.expira_em is null or a.expira_em > v_agora)
      and o.situacao = 'elegivel'
      and o.disponivel
  ) then
    return false;
  end if;

  update public.fila_publicacao
    set situacao = 'despachando',
        chave_despacho = p_chave_despacho,
        despacho_iniciado_em = v_agora
    where id = p_fila_id;

  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- poe_destino_em_quarentena: trava o canal ate reconciliacao humana.
-- ---------------------------------------------------------------------------
create function public.poe_destino_em_quarentena(
  p_canal text,
  p_destino text,
  p_fila_id bigint,
  p_motivo text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.estado_destino (canal, destino, fila_reservada_id, reservado_ate, quarentena_em, quarentena_motivo)
  values (p_canal, p_destino, p_fila_id, 'infinity'::timestamptz, now(), left(p_motivo, 500))
  on conflict (canal, destino) do update
    set reservado_ate = 'infinity'::timestamptz,
        quarentena_em = coalesce(public.estado_destino.quarentena_em, now()),
        quarentena_motivo = coalesce(public.estado_destino.quarentena_motivo, left(p_motivo, 500));

  update public.fila_publicacao
    set situacao = 'descartada',
        ultimo_erro_codigo = 'resultado_desconhecido',
        ultimo_erro_mensagem = left(p_motivo, 2000)
    where id = p_fila_id
      and situacao not in ('publicada', 'cancelada');
end;
$$;

-- ---------------------------------------------------------------------------
-- marcar_publicacao_concluida: registra o que saiu e libera o destino.
-- ---------------------------------------------------------------------------
create function public.marcar_publicacao_concluida(
  p_fila_id bigint,
  p_token_reserva uuid,
  p_id_mensagem_externa text,
  p_permalink text default null,
  p_metadados jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.fila_publicacao;
  v_publicacao_id bigint;
  v_agora timestamptz := now();
begin
  select * into v_item from public.fila_publicacao where id = p_fila_id for update;

  if not found then
    raise exception 'Item de fila % nao encontrado', p_fila_id using errcode = 'P0002';
  end if;

  if v_item.situacao <> 'despachando' or v_item.token_reserva is distinct from p_token_reserva then
    raise exception 'Item % nao esta em despacho com este token', p_fila_id using errcode = '22023';
  end if;

  insert into public.publicacoes (
    fila_id, oferta_id, canal, destino, id_mensagem_externa,
    chave_idempotencia, permalink, publicado_em, snapshot_payload, hash_payload, metadados_provedor
  )
  values (
    v_item.id, v_item.oferta_id, v_item.canal, v_item.destino, p_id_mensagem_externa,
    v_item.chave_idempotencia, p_permalink, v_agora, v_item.payload, v_item.hash_payload,
    coalesce(p_metadados, '{}'::jsonb)
  )
  returning id into v_publicacao_id;

  update public.fila_publicacao
    set situacao = 'publicada',
        reservada_por = null,
        token_reserva = null,
        reservada_em = null,
        reserva_expira_em = null
    where id = p_fila_id;

  update public.estado_destino
    set fila_reservada_id = null,
        reservado_ate = null,
        publicado_em = v_agora
    where canal = v_item.canal and destino = v_item.destino;

  return v_publicacao_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- marcar_publicacao_falha: retentativa com recuo exponencial, ou descarte.
-- Falha DEPOIS do despacho com resultado desconhecido vira quarentena.
-- ---------------------------------------------------------------------------
create function public.marcar_publicacao_falha(
  p_fila_id bigint,
  p_token_reserva uuid,
  p_codigo text,
  p_mensagem text,
  p_retentavel boolean default true,
  p_esperar_segundos integer default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.fila_publicacao;
  v_agora timestamptz := now();
  v_tentativas smallint;
  v_espera integer;
  v_situacao text;
begin
  select * into v_item from public.fila_publicacao where id = p_fila_id for update;

  if not found then
    raise exception 'Item de fila % nao encontrado', p_fila_id using errcode = 'P0002';
  end if;

  if v_item.token_reserva is distinct from p_token_reserva then
    raise exception 'Token de reserva nao confere para o item %', p_fila_id using errcode = '22023';
  end if;

  -- Ja tinha comecado a sair e nao sabemos o desfecho: trava o canal.
  if v_item.situacao = 'despachando' and not p_retentavel then
    perform public.poe_destino_em_quarentena(
      v_item.canal, v_item.destino, v_item.id,
      coalesce(p_mensagem, 'Falha apos o inicio do despacho')
    );
    return 'quarentena';
  end if;

  v_tentativas := v_item.tentativas + 1;

  if not p_retentavel or v_tentativas >= v_item.max_tentativas then
    v_situacao := 'descartada';
  else
    v_situacao := 'retentar';
    -- Recuo exponencial, teto de uma hora; 429 pode pedir espera propria.
    v_espera := coalesce(p_esperar_segundos, least(60 * power(2, v_tentativas)::integer, 3600));
  end if;

  update public.fila_publicacao
    set situacao = v_situacao,
        tentativas = v_tentativas,
        proxima_tentativa_em = case when v_situacao = 'retentar'
          then v_agora + make_interval(secs => v_espera) else null end,
        ultimo_erro_codigo = left(p_codigo, 80),
        ultimo_erro_mensagem = left(p_mensagem, 2000),
        reservada_por = null,
        token_reserva = null,
        reservada_em = null,
        reserva_expira_em = null
    where id = p_fila_id;

  -- Solta o destino: a falha foi antes de qualquer coisa sair.
  update public.estado_destino
    set fila_reservada_id = null,
        reservado_ate = null
    where canal = v_item.canal
      and destino = v_item.destino
      and quarentena_em is null;

  return v_situacao;
end;
$$;

-- ---------------------------------------------------------------------------
-- reconciliar_destino: so uma pessoa decide se a mensagem saiu ou nao.
-- ---------------------------------------------------------------------------
create function public.reconciliar_destino(
  p_canal text,
  p_destino text,
  p_desfecho text,
  p_id_mensagem_externa text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_estado public.estado_destino;
begin
  if p_desfecho not in ('entregue', 'nao_entregue') then
    raise exception 'Desfecho invalido: %', p_desfecho using errcode = '22023';
  end if;

  select * into v_estado from public.estado_destino
  where canal = p_canal and destino = p_destino for update;

  if not found or v_estado.quarentena_em is null then
    raise exception 'Destino %:% nao esta em quarentena', p_canal, p_destino using errcode = 'P0002';
  end if;

  if p_desfecho = 'entregue' then
    if p_id_mensagem_externa is null then
      raise exception 'Informe o id da mensagem para confirmar a entrega' using errcode = '22023';
    end if;

    insert into public.publicacoes (
      fila_id, oferta_id, canal, destino, id_mensagem_externa,
      chave_idempotencia, snapshot_payload, hash_payload
    )
    select f.id, f.oferta_id, f.canal, f.destino, p_id_mensagem_externa,
           f.chave_idempotencia, f.payload, f.hash_payload
    from public.fila_publicacao f
    where f.id = v_estado.fila_reservada_id
    on conflict do nothing;
  end if;

  update public.estado_destino
    set quarentena_em = null,
        quarentena_motivo = null,
        reservado_ate = null,
        fila_reservada_id = null,
        publicado_em = case when p_desfecho = 'entregue' then now() else publicado_em end
    where canal = p_canal and destino = p_destino;
end;
$$;

-- ---------------------------------------------------------------------------
-- cancelar_aprovacoes_vencidas: faxina.
--
-- Correcao em relacao ao motor de referencia: la o UPDATE juntava por
-- oferta e is_current, e nao pela aprovacao do proprio item. Isso cancelava
-- o item errado quando a oferta ganhava uma aprovacao nova, e deixava itens
-- em 'retentar' presos ate estourar as tentativas. Aqui a juncao e pelo id
-- da aprovacao e o filtro cobre 'pendente' e 'retentar'.
-- ---------------------------------------------------------------------------
create function public.cancelar_aprovacoes_vencidas()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total integer;
begin
  with vencidos as (
    update public.fila_publicacao f
      set situacao = 'cancelada',
          ultimo_erro_codigo = 'aprovacao_vencida',
          ultimo_erro_mensagem = 'A aprovacao deste item deixou de valer antes da publicacao',
          reservada_por = null,
          token_reserva = null,
          reservada_em = null,
          reserva_expira_em = null
      from public.aprovacoes a
      where a.id = f.aprovacao_id
        and f.situacao in ('pendente', 'retentar')
        and (
          a.decisao <> 'aprovada'
          or not a.vigente
          or (a.expira_em is not null and a.expira_em <= now())
        )
      returning f.id
  )
  select count(*) into v_total from vencidos;

  return v_total;
end;
$$;

-- ---------------------------------------------------------------------------
-- liberar_reservas_vencidas: reserva que estourou o prazo sem despachar
-- volta para a fila. Reserva que estourou JA despachando nao volta nunca.
-- ---------------------------------------------------------------------------
create function public.liberar_reservas_vencidas()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total integer;
  v_travado record;
begin
  with soltos as (
    update public.fila_publicacao
      set situacao = 'pendente',
          reservada_por = null,
          token_reserva = null,
          reservada_em = null,
          reserva_expira_em = null
      where situacao = 'reservada'
        and reserva_expira_em <= now()
      returning id, canal, destino
  )
  select count(*) into v_total from soltos;

  update public.estado_destino e
    set fila_reservada_id = null,
        reservado_ate = null
    where e.quarentena_em is null
      and e.reservado_ate is not null
      and e.reservado_ate <= now();

  -- Despacho pendurado: o provedor pode ter aceitado. Quarentena.
  for v_travado in
    select id, canal, destino from public.fila_publicacao
    where situacao = 'despachando'
      and despacho_iniciado_em <= now() - interval '10 minutes'
  loop
    perform public.poe_destino_em_quarentena(
      v_travado.canal, v_travado.destino, v_travado.id,
      'Despacho sem desfecho ha mais de 10 minutos'
    );
  end loop;

  return v_total;
end;
$$;

-- ---------------------------------------------------------------------------
-- Somente o service_role (Edge Functions) executa. O navegador, nunca.
-- ---------------------------------------------------------------------------
revoke execute on function
  public.reservar_item_da_fila(text, smallint),
  public.marcar_despacho_iniciado(bigint, uuid, text),
  public.poe_destino_em_quarentena(text, text, bigint, text),
  public.marcar_publicacao_concluida(bigint, uuid, text, text, jsonb),
  public.marcar_publicacao_falha(bigint, uuid, text, text, boolean, integer),
  public.reconciliar_destino(text, text, text, text),
  public.cancelar_aprovacoes_vencidas(),
  public.liberar_reservas_vencidas()
from anon, authenticated, public;

grant execute on function
  public.reservar_item_da_fila(text, smallint),
  public.marcar_despacho_iniciado(bigint, uuid, text),
  public.marcar_publicacao_concluida(bigint, uuid, text, text, jsonb),
  public.marcar_publicacao_falha(bigint, uuid, text, text, boolean, integer),
  public.cancelar_aprovacoes_vencidas(),
  public.liberar_reservas_vencidas()
to service_role;
