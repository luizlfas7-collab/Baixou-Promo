-- Os parametros de saida canal/destino colidiam com as colunas homonimas no
-- "on conflict (canal, destino)", que nao aceita qualificacao. Troca o upsert
-- por update-e-insere, onde todas as referencias podem ser qualificadas.
create or replace function public.reservar_item_da_fila(
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
      and a.decisao = 'aprovada'
      and a.vigente
      and (a.expira_em is null or a.expira_em > v_agora)
      and o.situacao = 'elegivel'
      and o.disponivel
      and (o.expira_em is null or o.expira_em > v_agora)
      and fo.habilitada
    order by f.prioridade desc, f.agendada_para, f.id
    for update of f skip locked
  loop
    exit when v_reservados >= v_lote;

    if not pg_try_advisory_xact_lock(hashtextextended(v_item.canal || ':' || v_item.destino, 0)) then
      continue;
    end if;

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

    update public.estado_destino e
      set fila_reservada_id = v_item.id,
          reservado_ate = v_expira
      where e.canal = v_item.canal and e.destino = v_item.destino;

    if not found then
      insert into public.estado_destino (canal, destino, fila_reservada_id, reservado_ate)
      values (v_item.canal, v_item.destino, v_item.id, v_expira);
    end if;

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

revoke execute on function public.reservar_item_da_fila(text, smallint) from anon, authenticated, public;
grant execute on function public.reservar_item_da_fila(text, smallint) to service_role;
