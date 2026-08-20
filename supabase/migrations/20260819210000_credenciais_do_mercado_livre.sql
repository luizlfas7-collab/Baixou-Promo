-- ---------------------------------------------------------------------------
-- Credenciais do Mercado Livre, moradas no cofre.
--
-- O motor de referencia (Radar Rota) guardava o token com DPAPI do Windows e
-- dependia de um script PowerShell rodando naquela maquina especifica: a
-- automacao inteira morria junto com o PC. Aqui o segredo mora no cofre do
-- banco e quem renova e a propria nuvem.
--
-- Nenhum segredo nesta tabela: so metadado que pode aparecer num painel.
-- ---------------------------------------------------------------------------
create table public.credenciais_ml (
  id smallint primary key default 1
    constraint credenciais_ml_singleton_ck check (id = 1),
  client_id text not null default ''
    constraint credenciais_ml_client_id_ck check (
      client_id = '' or client_id ~ '^[0-9]{6,32}$'
    ),
  redirect_uri text not null default ''
    constraint credenciais_ml_redirect_ck check (
      redirect_uri = '' or redirect_uri ~ '^https://[a-z0-9.-]+/[A-Za-z0-9/_-]*$'
    ),
  usuario_id text
    constraint credenciais_ml_usuario_ck check (
      usuario_id is null or usuario_id ~ '^[0-9]{1,20}$'
    ),
  escopos text
    constraint credenciais_ml_escopos_ck check (
      escopos is null or char_length(escopos) <= 200
    ),
  conectado_em timestamptz,
  expira_em timestamptz,
  renovado_em timestamptz,
  atualizado_em timestamptz not null default now()
);

comment on table public.credenciais_ml is
  'Metadado da conexao com o Mercado Livre. Os segredos ficam no cofre.';

insert into public.credenciais_ml (id) values (1);

alter table public.credenciais_ml enable row level security;

create policy "operador ativo le credenciais do ml"
  on public.credenciais_ml for select to authenticated
  using (public.eh_operador_ativo());

create trigger ao_atualizar_credenciais_ml
  before update on public.credenciais_ml
  for each row execute function public.toca_atualizado_em();

create trigger auditar after insert or update or delete on public.credenciais_ml
  for each row execute function public.grava_auditoria();

-- ---------------------------------------------------------------------------
-- cofre_gravar: upsert por nome. O vault recusa nome repetido no create, e
-- espalhar esse if/else por cada chamada e como se esquece um dos lados.
-- ---------------------------------------------------------------------------
create function public.cofre_gravar(p_nome text, p_valor text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_nome is null or p_nome !~ '^[a-z][a-z0-9_]{2,79}$' then
    raise exception 'Nome de segredo invalido: %', p_nome using errcode = '22023';
  end if;

  if p_valor is null or length(btrim(p_valor)) < 8 then
    raise exception 'Segredo % curto demais para ser real', p_nome using errcode = '22023';
  end if;

  select id into v_id from vault.secrets where name = p_nome;

  if v_id is null then
    perform vault.create_secret(btrim(p_valor), p_nome, 'Baixou');
  else
    perform vault.update_secret(v_id, btrim(p_valor));
  end if;
end;
$$;

revoke execute on function public.cofre_gravar(text, text) from anon, authenticated, public;

-- ---------------------------------------------------------------------------
-- oauth_ml_pendencias: o state e o verificador PKCE, entre o inicio do fluxo
-- e a volta do Mercado Livre. Vida curta de proposito.
-- ---------------------------------------------------------------------------
create table public.oauth_ml_pendencias (
  estado text primary key
    constraint oauth_ml_estado_ck check (estado ~ '^[A-Za-z0-9_-]{32,128}$'),
  verificador text not null
    constraint oauth_ml_verificador_ck check (verificador ~ '^[A-Za-z0-9_-]{43,128}$'),
  criado_em timestamptz not null default now(),
  expira_em timestamptz not null,
  constraint oauth_ml_prazo_ck check (expira_em > criado_em)
);

comment on table public.oauth_ml_pendencias is
  'State e verificador PKCE em transito. Some assim que o fluxo termina.';

alter table public.oauth_ml_pendencias enable row level security;
-- Sem politica: nem o painel precisa ler isto.

-- ---------------------------------------------------------------------------
-- oauth_ml_iniciar: cria o par state/verificador e devolve o desafio S256
-- pronto para montar a URL de autorizacao.
-- ---------------------------------------------------------------------------
create function public.oauth_ml_iniciar()
returns table (estado text, desafio text, client_id text, redirect_uri text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_estado text;
  v_verificador text;
  v_desafio text;
  v_cfg public.credenciais_ml;
begin
  select * into v_cfg from public.credenciais_ml where id = 1;

  if v_cfg.client_id = '' or v_cfg.redirect_uri = '' then
    raise exception 'Aplicacao do Mercado Livre ainda nao foi configurada'
      using errcode = 'P0002';
  end if;

  -- Base64url sem padding, direto dos bytes aleatorios.
  v_estado := translate(rtrim(encode(extensions.gen_random_bytes(32), 'base64'), '='), '+/', '-_');
  v_verificador := translate(rtrim(encode(extensions.gen_random_bytes(48), 'base64'), '='), '+/', '-_');
  v_desafio := translate(
    rtrim(encode(sha256(convert_to(v_verificador, 'UTF8')), 'base64'), '='),
    '+/', '-_'
  );

  -- Faxina oportunista: pendencia vencida nao serve para nada.
  delete from public.oauth_ml_pendencias where expira_em <= now();

  insert into public.oauth_ml_pendencias (estado, verificador, expira_em)
  values (v_estado, v_verificador, now() + interval '15 minutes');

  estado := v_estado;
  desafio := v_desafio;
  client_id := v_cfg.client_id;
  redirect_uri := v_cfg.redirect_uri;
  return next;
end;
$$;

revoke execute on function public.oauth_ml_iniciar() from anon, authenticated, public;
grant execute on function public.oauth_ml_iniciar() to service_role;

-- ---------------------------------------------------------------------------
-- oauth_ml_resgatar: entrega o verificador uma unica vez, conferindo o state.
-- Consumir apaga: replay do mesmo callback nao passa duas vezes.
-- ---------------------------------------------------------------------------
create function public.oauth_ml_resgatar(p_estado text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_verificador text;
begin
  delete from public.oauth_ml_pendencias
  where estado = p_estado and expira_em > now()
  returning verificador into v_verificador;

  if v_verificador is null then
    raise exception 'State desconhecido ou vencido' using errcode = '22023';
  end if;

  return v_verificador;
end;
$$;

revoke execute on function public.oauth_ml_resgatar(text) from anon, authenticated, public;
grant execute on function public.oauth_ml_resgatar(text) to service_role;

-- ---------------------------------------------------------------------------
-- oauth_ml_gravar_tokens: guarda access e refresh no cofre e atualiza o
-- metadado. O refresh do Mercado Livre e rotativo: a cada renovacao vem um
-- novo, e perder o novo significa perder o acesso na renovacao seguinte.
-- ---------------------------------------------------------------------------
create function public.oauth_ml_gravar_tokens(
  p_access_token text,
  p_refresh_token text,
  p_expires_in integer,
  p_usuario_id text default null,
  p_escopos text default null,
  p_primeira_conexao boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_expires_in is null or p_expires_in < 300 then
    raise exception 'expires_in implausivel: %', p_expires_in using errcode = '22023';
  end if;

  perform public.cofre_gravar('baixou_ml_access_token', p_access_token);
  perform public.cofre_gravar('baixou_ml_refresh_token', p_refresh_token);

  update public.credenciais_ml
    set usuario_id = coalesce(p_usuario_id, usuario_id),
        escopos = coalesce(p_escopos, escopos),
        expira_em = now() + make_interval(secs => p_expires_in),
        renovado_em = now(),
        conectado_em = case
          when p_primeira_conexao then now()
          else coalesce(conectado_em, now())
        end
    where id = 1;
end;
$$;

revoke execute on function public.oauth_ml_gravar_tokens(text, text, integer, text, text, boolean)
  from anon, authenticated, public;
grant execute on function public.oauth_ml_gravar_tokens(text, text, integer, text, text, boolean)
  to service_role;

-- ---------------------------------------------------------------------------
-- ml_credenciais_para_uso: tudo que o coletor precisa, numa leitura so.
-- ---------------------------------------------------------------------------
create function public.ml_credenciais_para_uso()
returns table (
  client_id text,
  client_secret text,
  redirect_uri text,
  access_token text,
  refresh_token text,
  expira_em timestamptz,
  precisa_renovar boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cfg public.credenciais_ml;
begin
  select * into v_cfg from public.credenciais_ml where id = 1;

  if not found or v_cfg.client_id = '' then
    raise exception 'Mercado Livre nao conectado' using errcode = 'P0002';
  end if;

  client_id := v_cfg.client_id;
  redirect_uri := v_cfg.redirect_uri;
  expira_em := v_cfg.expira_em;

  select decrypted_secret into client_secret
  from vault.decrypted_secrets where name = 'baixou_ml_client_secret';

  select decrypted_secret into access_token
  from vault.decrypted_secrets where name = 'baixou_ml_access_token';

  select decrypted_secret into refresh_token
  from vault.decrypted_secrets where name = 'baixou_ml_refresh_token';

  -- Cinco minutos de folga: renovar cedo custa uma chamada, renovar tarde
  -- custa a rodada inteira.
  precisa_renovar := v_cfg.expira_em is null
    or v_cfg.expira_em <= now() + interval '5 minutes'
    or access_token is null;

  return next;
end;
$$;

revoke execute on function public.ml_credenciais_para_uso() from anon, authenticated, public;
grant execute on function public.ml_credenciais_para_uso() to service_role;

-- ---------------------------------------------------------------------------
-- ml_conexao_estado: leitura segura para painel. Nunca devolve segredo.
-- ---------------------------------------------------------------------------
create function public.ml_conexao_estado()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'configurada', c.client_id <> '' and c.redirect_uri <> '',
    'conectada', exists (select 1 from vault.secrets where name = 'baixou_ml_refresh_token'),
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
