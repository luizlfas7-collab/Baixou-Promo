-- ---------------------------------------------------------------------------
-- configuracoes: linha unica com as porteiras do motor.
-- ---------------------------------------------------------------------------
create table public.configuracoes (
  id smallint primary key default 1
    constraint configuracoes_singleton_ck check (id = 1),

  automacao_ativa boolean not null default false,
  trava_emergencia boolean not null default true,
  exige_aprovacao_humana boolean not null default true,
  coleta_ativa boolean not null default false,
  aprovacao_automatica_ativa boolean not null default false,
  raia_rapida_ativa boolean not null default false,

  respeitar_janela boolean not null default true,
  fuso text not null default 'America/Sao_Paulo',
  janela_inicio time not null default '07:00',
  janela_fim time not null default '23:00',

  intervalo_minimo_segundos integer not null default 600
    constraint configuracoes_intervalo_ck check (intervalo_minimo_segundos between 60 and 86400),
  max_publicacoes_por_hora smallint not null default 6
    constraint configuracoes_por_hora_ck check (max_publicacoes_por_hora between 1 and 60),
  max_publicacoes_por_dia smallint not null default 60
    constraint configuracoes_por_dia_ck check (max_publicacoes_por_dia between 1 and 500),

  ttl_reserva_segundos integer not null default 180
    constraint configuracoes_ttl_ck check (ttl_reserva_segundos between 30 and 3600),
  max_lote_reserva smallint not null default 1
    constraint configuracoes_lote_ck check (max_lote_reserva between 1 and 50),

  aprovacao_versao_regra text not null default 'baixou-v1'
    constraint configuracoes_versao_regra_ck check (aprovacao_versao_regra ~ '^[a-z0-9][a-z0-9-]{2,80}$'),
  aprovacao_pontuacao_minima smallint not null default 88
    constraint configuracoes_pontuacao_ck check (aprovacao_pontuacao_minima between 70 and 100),
  aprovacao_desconto_minimo numeric(5, 2) not null default 15
    constraint configuracoes_desconto_ck check (aprovacao_desconto_minimo between 0 and 90),
  aprovacao_amostras_minimas smallint not null default 3
    constraint configuracoes_amostras_ck check (aprovacao_amostras_minimas between 2 and 24),
  aprovacao_historico_minimo_minutos integer not null default 360
    constraint configuracoes_historico_ck check (aprovacao_historico_minimo_minutos between 0 and 43200),
  aprovacao_nota_minima numeric(3, 2) not null default 4.60
    constraint configuracoes_nota_ck check (aprovacao_nota_minima between 0 and 5),
  aprovacao_avaliacoes_minimas integer not null default 50
    constraint configuracoes_avaliacoes_ck check (aprovacao_avaliacoes_minimas >= 0),
  aprovacao_idade_maxima_segundos integer not null default 3600
    constraint configuracoes_idade_ck check (aprovacao_idade_maxima_segundos between 60 and 86400),
  aprovacao_descanso_item_segundos integer not null default 604800
    constraint configuracoes_descanso_ck check (aprovacao_descanso_item_segundos between 3600 and 7776000),

  atualizado_por uuid references auth.users (id) on delete set null,
  atualizado_em timestamptz not null default now(),

  -- Janela precisa fazer sentido.
  constraint configuracoes_janela_ck check (janela_inicio < janela_fim),

  -- Os tres freios de ritmo tem que ser coerentes entre si: o motor anterior
  -- tinha teto por hora que nunca era atingido e teto diario ordens de
  -- grandeza acima do que o intervalo permitia.
  constraint configuracoes_ritmo_hora_ck check (
    max_publicacoes_por_hora <= floor(3600.0 / intervalo_minimo_segundos)
  ),
  constraint configuracoes_ritmo_dia_ck check (
    max_publicacoes_por_dia <= max_publicacoes_por_hora * 24
  ),

  -- So se pode desligar a revisao humana se a politica automatica estiver ligada.
  constraint configuracoes_porteira_humana_ck check (
    exige_aprovacao_humana or aprovacao_automatica_ativa
  ),
  -- Aprovacao automatica exige coleta ligada.
  constraint configuracoes_porteira_coleta_ck check (
    not aprovacao_automatica_ativa or coleta_ativa
  )
);

insert into public.configuracoes (id) values (1);

create trigger ao_atualizar_configuracoes
  before update on public.configuracoes
  for each row execute function public.toca_atualizado_em();

-- ---------------------------------------------------------------------------
-- execucoes: cada rodada de coletor ou publicador.
-- ---------------------------------------------------------------------------
create table public.execucoes (
  id bigint primary key generated always as identity,
  fonte_id bigint references public.fontes (id) on delete set null,
  chave_execucao text not null unique
    constraint execucoes_chave_ck check (char_length(chave_execucao) between 1 and 240),
  tipo text not null
    constraint execucoes_tipo_ck check (tipo in (
      'coleta', 'enriquecimento', 'aprovacao', 'publicacao', 'manutencao'
    )),
  situacao text not null default 'rodando'
    constraint execucoes_situacao_ck check (situacao in (
      'rodando', 'concluida', 'parcial', 'falhou', 'ignorada'
    )),
  identificador_worker text,
  iniciada_em timestamptz not null default now(),
  encerrada_em timestamptz,
  itens_vistos integer not null default 0,
  itens_inseridos integer not null default 0,
  itens_atualizados integer not null default 0,
  itens_recusados integer not null default 0,
  itens_enfileirados integer not null default 0,
  itens_publicados integer not null default 0,
  resumo_erro text
    constraint execucoes_resumo_ck check (resumo_erro is null or char_length(resumo_erro) <= 2000),
  metadados jsonb not null default '{}'::jsonb
    constraint execucoes_metadados_objeto_ck check (jsonb_typeof(metadados) = 'object')
    constraint execucoes_metadados_seguro_ck check (not public.contem_dado_sensivel(metadados))
);

create index execucoes_fonte_idx on public.execucoes (fonte_id, iniciada_em desc);
create index execucoes_situacao_idx on public.execucoes (situacao, iniciada_em desc);

-- ---------------------------------------------------------------------------
-- erros: falhas com deduplicacao por chave.
-- ---------------------------------------------------------------------------
create table public.erros (
  id bigint primary key generated always as identity,
  execucao_id bigint references public.execucoes (id) on delete set null,
  fila_id bigint references public.fila_publicacao (id) on delete set null,
  oferta_id bigint references public.ofertas (id) on delete set null,
  chave_idempotencia text not null unique
    constraint erros_chave_ck check (char_length(chave_idempotencia) between 1 and 240),
  gravidade text not null default 'erro'
    constraint erros_gravidade_ck check (gravidade in ('info', 'alerta', 'erro', 'critico')),
  codigo text not null
    constraint erros_codigo_ck check (codigo ~ '^[a-z0-9][a-z0-9_]{2,80}$'),
  mensagem text not null
    constraint erros_mensagem_ck check (char_length(mensagem) between 1 and 2000),
  contexto jsonb not null default '{}'::jsonb
    constraint erros_contexto_objeto_ck check (jsonb_typeof(contexto) = 'object')
    constraint erros_contexto_seguro_ck check (not public.contem_dado_sensivel(contexto)),
  ocorrencias integer not null default 1
    constraint erros_ocorrencias_ck check (ocorrencias > 0),
  visto_primeiro_em timestamptz not null default now(),
  visto_ultimo_em timestamptz not null default now(),
  resolvido_em timestamptz
);

create index erros_execucao_idx on public.erros (execucao_id) where execucao_id is not null;
create index erros_fila_idx on public.erros (fila_id) where fila_id is not null;
create index erros_oferta_idx on public.erros (oferta_id) where oferta_id is not null;
create index erros_abertos_idx
  on public.erros (gravidade, visto_ultimo_em desc)
  where resolvido_em is null;

-- ---------------------------------------------------------------------------
-- auditoria: trilha automatica das tabelas sensiveis.
-- ---------------------------------------------------------------------------
create table public.auditoria (
  id bigint primary key generated always as identity,
  chave_idempotencia text not null unique,
  papel_ator text not null,
  acao text not null
    constraint auditoria_acao_ck check (acao in ('insercao', 'atualizacao', 'remocao')),
  tabela text not null,
  chave_entidade text not null,
  dados_antes jsonb,
  dados_depois jsonb,
  ocorrido_em timestamptz not null default now()
);

create index auditoria_entidade_idx on public.auditoria (tabela, chave_entidade, ocorrido_em desc);
create index auditoria_data_idx on public.auditoria (ocorrido_em desc);

create function public.grava_auditoria()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acao text;
  v_antes jsonb;
  v_depois jsonb;
  v_chave text;
  -- Colunas que nunca entram na trilha.
  v_ocultas text[] := array[
    'configuracao', 'payload_origem', 'payload', 'snapshot_payload',
    'metadados_provedor', 'contexto', 'token_reserva', 'metadados'
  ];
begin
  v_acao := case tg_op
    when 'INSERT' then 'insercao'
    when 'UPDATE' then 'atualizacao'
    else 'remocao'
  end;

  if tg_op <> 'INSERT' then
    v_antes := to_jsonb(old) - v_ocultas;
  end if;

  if tg_op <> 'DELETE' then
    v_depois := to_jsonb(new) - v_ocultas;
  end if;

  v_chave := coalesce(v_depois ->> 'id', v_antes ->> 'id', '');

  insert into public.auditoria (
    chave_idempotencia, papel_ator, acao, tabela, chave_entidade, dados_antes, dados_depois
  )
  values (
    concat_ws(':', tg_table_name, v_acao, v_chave, gen_random_uuid()::text),
    session_user,
    v_acao,
    tg_table_name,
    v_chave,
    v_antes,
    v_depois
  );

  return null;
end;
$$;

revoke execute on function public.grava_auditoria() from anon, authenticated, public;

create trigger auditar after insert or update or delete on public.configuracoes
  for each row execute function public.grava_auditoria();
create trigger auditar after insert or update or delete on public.fontes
  for each row execute function public.grava_auditoria();
create trigger auditar after insert or update or delete on public.aprovacoes
  for each row execute function public.grava_auditoria();
create trigger auditar after insert or update or delete on public.fila_publicacao
  for each row execute function public.grava_auditoria();
create trigger auditar after insert or update or delete on public.estado_destino
  for each row execute function public.grava_auditoria();
create trigger auditar after insert or update or delete on public.publicacoes
  for each row execute function public.grava_auditoria();

-- ---------------------------------------------------------------------------
-- Acesso.
-- ---------------------------------------------------------------------------
alter table public.configuracoes enable row level security;
alter table public.execucoes enable row level security;
alter table public.erros enable row level security;
alter table public.auditoria enable row level security;

create policy "operador ativo le configuracoes"
  on public.configuracoes for select to authenticated
  using (public.eh_operador_ativo());

create policy "operador ativo le execucoes"
  on public.execucoes for select to authenticated
  using (public.eh_operador_ativo());

create policy "operador ativo le erros"
  on public.erros for select to authenticated
  using (public.eh_operador_ativo());

-- auditoria nao tem politica: so o service_role enxerga.
