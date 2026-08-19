-- Substituicao integral da funcao, nunca patch sobre a definicao viva:
-- passa a usar o sha256 nativo, igual ao usado nas CHECK constraints.
create or replace function public.oferta_calcula_hash()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.hash_conteudo := encode(
    sha256(convert_to(
      jsonb_build_object(
        'titulo', new.titulo,
        'url_canonica', new.url_canonica,
        'url_afiliado', new.url_afiliado,
        'url_imagem', new.url_imagem,
        'moeda', new.moeda,
        'preco_atual', new.preco_atual,
        'preco_original', new.preco_original,
        'desconto_percentual', new.desconto_percentual,
        'codigo_cupom', new.codigo_cupom,
        'cupom_expira_em', new.cupom_expira_em,
        'disponivel', new.disponivel,
        'situacao', new.situacao,
        'expira_em', new.expira_em
      )::text,
      'UTF8'
    )),
    'hex'
  );

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- aprovacoes: a decisao de publicar, amarrada a uma versao exata da oferta
-- e a um payload exato.
-- ---------------------------------------------------------------------------
create table public.aprovacoes (
  id bigint primary key generated always as identity,
  oferta_id bigint not null references public.ofertas (id) on delete cascade,
  hash_conteudo_oferta text not null
    constraint aprovacoes_hash_oferta_ck check (hash_conteudo_oferta ~ '^[a-f0-9]{64}$'),
  hash_payload_aprovado text
    constraint aprovacoes_hash_payload_ck check (
      hash_payload_aprovado is null or hash_payload_aprovado ~ '^[a-f0-9]{64}$'
    ),
  chave_idempotencia text not null unique
    constraint aprovacoes_chave_ck check (char_length(chave_idempotencia) between 1 and 240),
  decisao text not null default 'pendente'
    constraint aprovacoes_decisao_ck check (decisao in ('pendente', 'aprovada', 'recusada', 'expirada')),
  origem_decisao text not null
    constraint aprovacoes_origem_ck check (origem_decisao in ('motor_regras', 'manual', 'fonte')),
  versao_regra text
    constraint aprovacoes_versao_regra_ck check (
      versao_regra is null or versao_regra ~ '^[a-z0-9][a-z0-9-]{2,80}$'
    ),
  pontuacao numeric(5, 2)
    constraint aprovacoes_pontuacao_ck check (pontuacao is null or pontuacao between 0 and 100),
  motivo text
    constraint aprovacoes_motivo_ck check (motivo is null or char_length(motivo) <= 2000),
  vigente boolean not null default true,
  revisor_id uuid references auth.users (id) on delete restrict,
  solicitada_em timestamptz not null default now(),
  decidida_em timestamptz,
  expira_em timestamptz,

  -- Aprovacao manual precisa dizer quem aprovou.
  constraint aprovacoes_revisor_obrigatorio_ck check (
    origem_decisao <> 'manual' or decisao <> 'aprovada' or revisor_id is not null
  ),
  -- Aprovada so vale enfileirada a um payload.
  constraint aprovacoes_payload_obrigatorio_ck check (
    decisao <> 'aprovada' or hash_payload_aprovado is not null
  ),

  -- Existem para viabilizar a chave estrangeira composta da fila.
  constraint aprovacoes_id_oferta_uk unique (id, oferta_id),
  constraint aprovacoes_binding_uk unique (id, oferta_id, hash_conteudo_oferta, hash_payload_aprovado)
);

create unique index aprovacoes_uma_vigente_por_oferta_idx
  on public.aprovacoes (oferta_id)
  where vigente;

create index aprovacoes_historico_idx on public.aprovacoes (oferta_id, solicitada_em desc);
create index aprovacoes_revisor_idx on public.aprovacoes (revisor_id) where revisor_id is not null;

-- Amarra a decisao a versao da oferta e congela o que ja foi decidido.
create function public.aprovacao_amarra_versao()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_hash_oferta text;
begin
  if tg_op = 'INSERT' then
    select o.hash_conteudo into v_hash_oferta
    from public.ofertas o
    where o.id = new.oferta_id;

    if v_hash_oferta is null then
      raise exception 'Oferta % nao encontrada', new.oferta_id using errcode = '23503';
    end if;

    new.hash_conteudo_oferta := v_hash_oferta;
    return new;
  end if;

  if new.id is distinct from old.id
     or new.oferta_id is distinct from old.oferta_id
     or new.hash_conteudo_oferta is distinct from old.hash_conteudo_oferta
     or new.chave_idempotencia is distinct from old.chave_idempotencia then
    raise exception 'Identidade e binding de uma aprovacao sao imutaveis'
      using errcode = '23514';
  end if;

  if old.decisao in ('aprovada', 'recusada', 'expirada')
     and new.decisao is distinct from old.decisao then
    raise exception 'Decisao ja terminal nao pode ser alterada de % para %', old.decisao, new.decisao
      using errcode = '23514';
  end if;

  if old.hash_payload_aprovado is not null
     and new.hash_payload_aprovado is distinct from old.hash_payload_aprovado then
    raise exception 'Payload aprovado e imutavel' using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke execute on function public.aprovacao_amarra_versao() from anon, authenticated, public;

create trigger ao_gravar_aprovacao
  before insert or update on public.aprovacoes
  for each row execute function public.aprovacao_amarra_versao();

-- ---------------------------------------------------------------------------
-- fila_publicacao: o que esta esperando para sair.
-- ---------------------------------------------------------------------------
create table public.fila_publicacao (
  id bigint primary key generated always as identity,
  oferta_id bigint not null references public.ofertas (id) on delete restrict,
  aprovacao_id bigint not null,
  hash_conteudo_oferta text not null,
  canal text not null default 'telegram'
    constraint fila_canal_ck check (canal in ('telegram', 'whatsapp', 'email', 'site')),
  destino text not null
    constraint fila_destino_ck check (char_length(destino) between 1 and 160),
  versao_conteudo integer not null default 1
    constraint fila_versao_ck check (versao_conteudo > 0),
  chave_idempotencia text not null unique
    constraint fila_chave_ck check (char_length(chave_idempotencia) between 1 and 240),
  situacao text not null default 'pendente'
    constraint fila_situacao_ck check (situacao in (
      'pendente', 'reservada', 'despachando', 'publicada', 'retentar', 'descartada', 'cancelada'
    )),
  prioridade smallint not null default 0,
  agendada_para timestamptz not null default now(),
  proxima_tentativa_em timestamptz,
  tentativas smallint not null default 0,
  max_tentativas smallint not null default 5,
  reservada_por text,
  token_reserva uuid,
  reservada_em timestamptz,
  reserva_expira_em timestamptz,
  chave_despacho text unique,
  despacho_iniciado_em timestamptz,
  ultimo_erro_codigo text,
  ultimo_erro_mensagem text
    constraint fila_erro_mensagem_ck check (
      ultimo_erro_mensagem is null or char_length(ultimo_erro_mensagem) <= 2000
    ),
  payload jsonb not null
    constraint fila_payload_objeto_ck check (jsonb_typeof(payload) = 'object')
    constraint fila_payload_seguro_ck check (not public.contem_dado_sensivel(payload)),
  hash_payload text not null
    constraint fila_hash_confere_ck check (
      hash_payload = encode(sha256(convert_to(payload::text, 'UTF8')), 'hex')
    ),
  raia text not null default 'confiavel'
    constraint fila_raia_ck check (raia in ('confiavel', 'rapida', 'cupom')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),

  constraint fila_tentativas_ck check (tentativas <= max_tentativas and max_tentativas between 1 and 20),

  -- O estado de reserva e tudo ou nada.
  constraint fila_reserva_coerente_ck check (
    (reservada_por is null and token_reserva is null and reservada_em is null and reserva_expira_em is null)
    or (reservada_por is not null and token_reserva is not null and reservada_em is not null and reserva_expira_em is not null)
  ),

  -- A peca central: e fisicamente impossivel enfileirar um payload diferente
  -- do aprovado, para uma versao de oferta diferente da aprovada.
  constraint fila_aprovacao_fk foreign key (aprovacao_id, oferta_id, hash_conteudo_oferta, hash_payload)
    references public.aprovacoes (id, oferta_id, hash_conteudo_oferta, hash_payload_aprovado),

  constraint fila_conteudo_uk unique (oferta_id, canal, destino, versao_conteudo),
  constraint fila_id_destino_uk unique (id, oferta_id, canal, destino)
);

create index fila_aprovacao_idx on public.fila_publicacao (aprovacao_id);

create index fila_a_publicar_idx
  on public.fila_publicacao (agendada_para, prioridade desc, id)
  include (canal, destino, raia)
  where situacao in ('pendente', 'retentar');

create index fila_reserva_vencida_idx
  on public.fila_publicacao (reserva_expira_em)
  where situacao = 'reservada';

create index fila_despacho_vencido_idx
  on public.fila_publicacao (despacho_iniciado_em)
  where situacao = 'despachando';

-- Identidade e conteudo aprovado sao imutaveis depois de enfileirados.
create function public.fila_protege_conteudo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.oferta_id is distinct from old.oferta_id
     or new.aprovacao_id is distinct from old.aprovacao_id
     or new.hash_conteudo_oferta is distinct from old.hash_conteudo_oferta
     or new.hash_payload is distinct from old.hash_payload
     or new.payload is distinct from old.payload
     or new.canal is distinct from old.canal
     or new.destino is distinct from old.destino
     or new.chave_idempotencia is distinct from old.chave_idempotencia then
    raise exception 'Identidade e conteudo aprovado de um item de fila sao imutaveis'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke execute on function public.fila_protege_conteudo() from anon, authenticated, public;

create trigger ao_atualizar_fila_protege
  before update on public.fila_publicacao
  for each row execute function public.fila_protege_conteudo();

create trigger ao_atualizar_fila
  before update on public.fila_publicacao
  for each row execute function public.toca_atualizado_em();

-- ---------------------------------------------------------------------------
-- estado_destino: reserva duravel do canal. E o que impede dois envios
-- simultaneos depois que a transacao de reserva commitou e o HTTP comecou.
-- ---------------------------------------------------------------------------
create table public.estado_destino (
  canal text not null
    constraint estado_destino_canal_ck check (canal in ('telegram', 'whatsapp', 'email', 'site')),
  destino text not null
    constraint estado_destino_destino_ck check (char_length(destino) between 1 and 160),
  fila_reservada_id bigint unique references public.fila_publicacao (id) on delete set null,
  reservado_ate timestamptz,
  publicado_em timestamptz,
  quarentena_em timestamptz,
  quarentena_motivo text
    constraint estado_destino_motivo_ck check (
      quarentena_motivo is null or char_length(quarentena_motivo) <= 500
    ),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),

  primary key (canal, destino),

  -- Quarentena trava o destino ate reconciliacao humana.
  constraint estado_destino_quarentena_ck check (
    quarentena_em is null
    or (reservado_ate = 'infinity'::timestamptz and quarentena_motivo is not null)
  )
);

create trigger ao_atualizar_estado_destino
  before update on public.estado_destino
  for each row execute function public.toca_atualizado_em();

-- ---------------------------------------------------------------------------
-- publicacoes: o que efetivamente saiu.
-- ---------------------------------------------------------------------------
create table public.publicacoes (
  id bigint primary key generated always as identity,
  fila_id bigint not null unique,
  oferta_id bigint not null,
  canal text not null,
  destino text not null,
  id_mensagem_externa text not null
    constraint publicacoes_mensagem_ck check (char_length(id_mensagem_externa) between 1 and 160),
  chave_idempotencia text not null unique,
  situacao text not null default 'publicada'
    constraint publicacoes_situacao_ck check (situacao in ('publicada', 'editada', 'removida')),
  permalink text
    constraint publicacoes_permalink_ck check (permalink is null or permalink ~ '^https://'),
  publicado_em timestamptz not null default now(),
  snapshot_payload jsonb not null
    constraint publicacoes_snapshot_objeto_ck check (jsonb_typeof(snapshot_payload) = 'object')
    constraint publicacoes_snapshot_seguro_ck check (not public.contem_dado_sensivel(snapshot_payload)),
  hash_payload text not null
    constraint publicacoes_hash_confere_ck check (
      hash_payload = encode(sha256(convert_to(snapshot_payload::text, 'UTF8')), 'hex')
    ),
  metadados_provedor jsonb not null default '{}'::jsonb
    constraint publicacoes_metadados_objeto_ck check (jsonb_typeof(metadados_provedor) = 'object')
    constraint publicacoes_metadados_seguro_ck check (not public.contem_dado_sensivel(metadados_provedor)),
  criado_em timestamptz not null default now(),

  constraint publicacoes_fila_fk foreign key (fila_id, oferta_id, canal, destino)
    references public.fila_publicacao (id, oferta_id, canal, destino),
  constraint publicacoes_mensagem_uk unique (canal, destino, id_mensagem_externa)
);

create index publicacoes_oferta_idx on public.publicacoes (oferta_id, publicado_em desc);
create index publicacoes_destino_idx on public.publicacoes (canal, destino, publicado_em desc);

-- ---------------------------------------------------------------------------
-- Acesso: painel le, navegador nunca escreve.
-- ---------------------------------------------------------------------------
alter table public.aprovacoes enable row level security;
alter table public.fila_publicacao enable row level security;
alter table public.estado_destino enable row level security;
alter table public.publicacoes enable row level security;

create policy "operador ativo le aprovacoes"
  on public.aprovacoes for select to authenticated
  using (public.eh_operador_ativo());

create policy "operador ativo le fila"
  on public.fila_publicacao for select to authenticated
  using (public.eh_operador_ativo());

create policy "operador ativo le estado do destino"
  on public.estado_destino for select to authenticated
  using (public.eh_operador_ativo());

create policy "operador ativo le publicacoes"
  on public.publicacoes for select to authenticated
  using (public.eh_operador_ativo());
