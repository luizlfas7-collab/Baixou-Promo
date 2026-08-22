-- ---------------------------------------------------------------------------
-- Endurecimento do OAuth, trazido do desenho do Radar Rota.
--
-- Tres buracos que o Baixou tinha:
--
-- 1. CORRIDA NA RENOVACAO. O refresh do Mercado Livre e rotativo: cada
--    renovacao invalida o anterior. Se duas rodadas do coletor se sobrepoem
--    com o token vencendo, as duas renovam, o ML rotaciona duas vezes, e a
--    ultima a gravar guarda um refresh ja morto. A conexao cai em silencio e
--    so volta com reautorizacao manual. Agora existe lease: so um renova.
--
-- 2. SEM ESTADO DE FALHA. Refresh revogado fazia o coletor bater no ML a cada
--    5 minutos, para sempre, sem ninguem saber. Agora a conexao tem situacao,
--    e 'reautorizacao_necessaria' para de tentar.
--
-- 3. SEM RECUO. Falha transitoria era retentada no mesmo ritmo. Agora tem
--    espera exponencial.
-- ---------------------------------------------------------------------------

alter table public.credenciais_ml
  add column if not exists situacao text not null default 'pronta',
  add column if not exists tentar_apos timestamptz,
  add column if not exists ultimo_erro_codigo text,
  add column if not exists geracao bigint not null default 1,
  add column if not exists locada_por text,
  add column if not exists lock_token uuid,
  add column if not exists locada_em timestamptz,
  add column if not exists lock_expira_em timestamptz;

alter table public.credenciais_ml
  drop constraint if exists credenciais_ml_situacao_ck;
alter table public.credenciais_ml
  add constraint credenciais_ml_situacao_ck check (
    situacao in ('pronta', 'aguardando_retentativa', 'reautorizacao_necessaria', 'pausada')
  );

alter table public.credenciais_ml
  drop constraint if exists credenciais_ml_geracao_ck;
alter table public.credenciais_ml
  add constraint credenciais_ml_geracao_ck check (geracao > 0);

alter table public.credenciais_ml
  drop constraint if exists credenciais_ml_erro_codigo_ck;
alter table public.credenciais_ml
  add constraint credenciais_ml_erro_codigo_ck check (
    ultimo_erro_codigo is null or ultimo_erro_codigo ~ '^[a-z0-9_]{3,120}$'
  );

-- O lease e tudo ou nada: meia trava e pior que nenhuma.
alter table public.credenciais_ml
  drop constraint if exists credenciais_ml_lease_ck;
alter table public.credenciais_ml
  add constraint credenciais_ml_lease_ck check (
    (locada_por is null and lock_token is null and locada_em is null and lock_expira_em is null)
    or (locada_por is not null and lock_token is not null and locada_em is not null
        and lock_expira_em is not null and lock_expira_em > locada_em)
  );

comment on column public.credenciais_ml.geracao is
  'Sobe a cada renovacao. Serve para detectar uso de token de geracao vencida.';
comment on column public.credenciais_ml.situacao is
  'pronta | aguardando_retentativa | reautorizacao_necessaria | pausada';

-- ---------------------------------------------------------------------------
-- ml_token_adquirir: unica porta de entrada do coletor para o token.
--
-- Devolve o token quando ele serve. Quando precisa renovar, TENTA pegar o
-- lease: quem pegar renova, quem nao pegar volta na proxima rodada. Nunca
-- duas renovacoes simultaneas.
-- ---------------------------------------------------------------------------
create or replace function public.ml_token_adquirir(
  p_worker text,
  p_ttl_segundos integer default 120
)
returns table (
  situacao text,
  motivo text,
  client_id text,
  client_secret text,
  access_token text,
  refresh_token text,
  expira_em timestamptz,
  precisa_renovar boolean,
  lock_token uuid,
  geracao bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.credenciais_ml;
  v_agora timestamptz := now();
  v_access text;
  v_refresh text;
  v_segredo text;
  v_precisa boolean;
  v_livre boolean;
  v_novo_lock uuid;
begin
  select * into v from public.credenciais_ml where id = 1 for update;

  if not found or v.client_id = '' then
    situacao := 'pausada';
    motivo := 'nao_configurada';
    precisa_renovar := false;
    return next;
    return;
  end if;

  if v.situacao = 'reautorizacao_necessaria' then
    situacao := v.situacao;
    motivo := coalesce(v.ultimo_erro_codigo, 'reautorizacao_necessaria');
    precisa_renovar := false;
    return next;
    return;
  end if;

  if v.situacao = 'pausada' then
    situacao := v.situacao;
    motivo := 'pausada_pelo_operador';
    precisa_renovar := false;
    return next;
    return;
  end if;

  select decrypted_secret into v_access
  from vault.decrypted_secrets where name = 'baixou_ml_access_token';
  select decrypted_secret into v_refresh
  from vault.decrypted_secrets where name = 'baixou_ml_refresh_token';
  select decrypted_secret into v_segredo
  from vault.decrypted_secrets where name = 'baixou_ml_client_secret';

  -- Cinco minutos de folga: renovar cedo custa uma chamada, renovar tarde
  -- custa a rodada inteira.
  v_precisa := v_access is null
    or v.expira_em is null
    or v.expira_em <= v_agora + interval '5 minutes';

  if not v_precisa then
    situacao := 'pronta';
    motivo := null;
    client_id := v.client_id;
    client_secret := v_segredo;
    access_token := v_access;
    refresh_token := v_refresh;
    expira_em := v.expira_em;
    precisa_renovar := false;
    lock_token := null;
    geracao := v.geracao;
    return next;
    return;
  end if;

  -- Daqui para baixo, precisa renovar.
  if v.situacao = 'aguardando_retentativa'
     and v.tentar_apos is not null and v.tentar_apos > v_agora then
    situacao := v.situacao;
    motivo := 'aguardando_retentativa';
    precisa_renovar := true;
    lock_token := null;
    return next;
    return;
  end if;

  -- Lease vencido pode ser tomado: worker que morreu no meio nao trava tudo.
  v_livre := v.lock_token is null or v.lock_expira_em <= v_agora;

  if not v_livre then
    situacao := v.situacao;
    motivo := 'renovacao_em_andamento';
    precisa_renovar := true;
    lock_token := null;
    return next;
    return;
  end if;

  v_novo_lock := extensions.gen_random_uuid();

  update public.credenciais_ml
    set locada_por = left(coalesce(nullif(btrim(p_worker), ''), 'anonimo'), 160),
        lock_token = v_novo_lock,
        locada_em = v_agora,
        lock_expira_em = v_agora + make_interval(secs => greatest(least(p_ttl_segundos, 900), 30))
    where id = 1;

  situacao := v.situacao;
  motivo := null;
  client_id := v.client_id;
  client_secret := v_segredo;
  access_token := v_access;
  refresh_token := v_refresh;
  expira_em := v.expira_em;
  precisa_renovar := true;
  lock_token := v_novo_lock;
  geracao := v.geracao;
  return next;
end;
$$;

revoke execute on function public.ml_token_adquirir(text, integer) from anon, authenticated, public;
grant execute on function public.ml_token_adquirir(text, integer) to service_role;

-- ---------------------------------------------------------------------------
-- ml_token_renovado: grava o par novo e solta o lease. So aceita de quem
-- realmente segura a trava.
-- ---------------------------------------------------------------------------
create or replace function public.ml_token_renovado(
  p_lock_token uuid,
  p_access_token text,
  p_refresh_token text,
  p_expires_in integer,
  p_escopos text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.credenciais_ml;
begin
  select * into v from public.credenciais_ml where id = 1 for update;

  if v.lock_token is distinct from p_lock_token then
    raise exception 'Lease nao confere: outra rodada renovou enquanto esta trabalhava'
      using errcode = '22023';
  end if;

  if p_expires_in is null or p_expires_in < 300 then
    raise exception 'expires_in implausivel: %', p_expires_in using errcode = '22023';
  end if;

  perform public.cofre_gravar('baixou_ml_access_token', p_access_token);
  perform public.cofre_gravar('baixou_ml_refresh_token', p_refresh_token);

  update public.credenciais_ml
    set expira_em = now() + make_interval(secs => p_expires_in),
        renovado_em = now(),
        escopos = coalesce(p_escopos, escopos),
        geracao = geracao + 1,
        situacao = 'pronta',
        tentar_apos = null,
        ultimo_erro_codigo = null,
        locada_por = null,
        lock_token = null,
        locada_em = null,
        lock_expira_em = null
    where id = 1
  returning geracao into v.geracao;

  return v.geracao;
end;
$$;

revoke execute on function public.ml_token_renovado(uuid, text, text, integer, text) from anon, authenticated, public;
grant execute on function public.ml_token_renovado(uuid, text, text, integer, text) to service_role;

-- ---------------------------------------------------------------------------
-- ml_token_falhou: registra o motivo, aplica recuo e solta o lease.
--
-- Falha permanente (refresh revogado, credencial trocada) nao adianta
-- retentar: marca reautorizacao_necessaria e para de tentar. Bater no ML a
-- cada 5 minutos com um refresh morto nao conserta nada e ainda queima cota.
-- ---------------------------------------------------------------------------
create or replace function public.ml_token_falhou(
  p_lock_token uuid,
  p_codigo text,
  p_permanente boolean default false
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.credenciais_ml;
  v_falhas integer;
  v_espera integer;
  v_situacao text;
begin
  select * into v from public.credenciais_ml where id = 1 for update;

  if v.lock_token is distinct from p_lock_token then
    raise exception 'Lease nao confere' using errcode = '22023';
  end if;

  if p_permanente then
    v_situacao := 'reautorizacao_necessaria';
    v_espera := null;
  else
    v_situacao := 'aguardando_retentativa';
    -- Recuo exponencial contado pelas falhas ja registradas, teto de 1 hora.
    v_falhas := case when v.situacao = 'aguardando_retentativa' then 1 else 0 end;
    v_espera := least(300 * power(2, v_falhas)::integer, 3600);
  end if;

  update public.credenciais_ml
    set situacao = v_situacao,
        ultimo_erro_codigo = lower(left(regexp_replace(coalesce(p_codigo, 'desconhecido'), '[^a-zA-Z0-9_]', '_', 'g'), 120)),
        tentar_apos = case when v_espera is null then null else now() + make_interval(secs => v_espera) end,
        locada_por = null,
        lock_token = null,
        locada_em = null,
        lock_expira_em = null
    where id = 1;

  return v_situacao;
end;
$$;

revoke execute on function public.ml_token_falhou(uuid, text, boolean) from anon, authenticated, public;
grant execute on function public.ml_token_falhou(uuid, text, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- ml_token_liberar: solta o lease sem mudar nada. Para quando o worker
-- desiste antes de tentar renovar.
-- ---------------------------------------------------------------------------
create or replace function public.ml_token_liberar(p_lock_token uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_soltou boolean := false;
begin
  update public.credenciais_ml
    set locada_por = null, lock_token = null, locada_em = null, lock_expira_em = null
    where id = 1 and lock_token = p_lock_token
  returning true into v_soltou;

  return coalesce(v_soltou, false);
end;
$$;

revoke execute on function public.ml_token_liberar(uuid) from anon, authenticated, public;
grant execute on function public.ml_token_liberar(uuid) to service_role;

-- Estado agora mostra a saude da conexao, nao so se existe token.
create or replace function public.ml_conexao_estado()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'configurada', c.client_id <> '' and c.redirect_uri <> '',
    'conectada', exists (select 1 from vault.secrets where name = 'baixou_ml_refresh_token'),
    'situacao', c.situacao,
    'ultimo_erro', c.ultimo_erro_codigo,
    'tentar_apos', c.tentar_apos,
    'geracao', c.geracao,
    'renovacao_em_andamento', c.lock_token is not null and c.lock_expira_em > now(),
    'usuario_id', c.usuario_id,
    'escopos', c.escopos,
    'conectado_em', c.conectado_em,
    'renovado_em', c.renovado_em,
    'expira_em', c.expira_em,
    'expirado', c.expira_em is not null and c.expira_em <= now()
  )
  from public.credenciais_ml c
  where c.id = 1;
$$;

revoke execute on function public.ml_conexao_estado() from anon, public;
grant execute on function public.ml_conexao_estado() to authenticated, service_role;

-- A conexao entra na vistoria de soltar a trava: reautorizacao pendente e
-- impedimento, nao detalhe.
create or replace function public.vistoria_para_soltar()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'ml_conectado', exists (select 1 from vault.secrets where name = 'baixou_ml_refresh_token'),
    'ml_situacao', (select situacao from public.credenciais_ml where id = 1),
    'telegram_configurado', (select destino_padrao <> '' from public.configuracoes where id = 1),
    'coleta_ativa', (select coleta_ativa from public.configuracoes where id = 1),
    'fonte_ml_ligada', (select habilitada from public.fontes where slug = 'mercado_livre_api_oficial'),
    'itens_na_watchlist', (select count(*) from public.itens_ml where habilitado and produto_catalogo is not null),
    'itens_com_historico_suficiente', (
      select count(*) from (
        select h.oferta_id from public.historico_precos h
        group by h.oferta_id having count(distinct h.preco) >= 2
      ) s
    ),
    'cron_agendado', (select count(*) from cron.job where active),
    'destino_em_quarentena', exists (select 1 from public.estado_destino where quarentena_em is not null),
    'trava_ligada', (select trava_emergencia from public.configuracoes where id = 1)
  );
$$;

revoke execute on function public.vistoria_para_soltar() from anon, public;
grant execute on function public.vistoria_para_soltar() to authenticated, service_role;
