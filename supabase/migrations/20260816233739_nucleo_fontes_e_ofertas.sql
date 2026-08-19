-- ---------------------------------------------------------------------------
-- Guarda anti-segredo, usada em CHECK nas colunas jsonb.
--
-- Diferenca deliberada em relacao ao motor anterior: la, qualquer string com
-- cara de e-mail, CEP ou telefone era recusada, e um titulo de produto com
-- codigo de peca nesse formato derrubava a coleta do item inteiro. Aqui a
-- checagem de valor mira credencial de verdade; e-mail e telefone continuam
-- barrados quando aparecem sob chave sensivel.
-- ---------------------------------------------------------------------------
create function public.contem_dado_sensivel(dados jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  chave text;
  valor jsonb;
  item jsonb;
  chave_normalizada text;
begin
  if dados is null then
    return false;
  end if;

  if jsonb_typeof(dados) = 'object' then
    for chave, valor in select * from jsonb_each(dados) loop
      chave_normalizada := regexp_replace(lower(chave), '[^a-z]', '', 'g');

      if chave_normalizada in (
        'token', 'secret', 'segredo', 'password', 'passwd', 'senha', 'apikey',
        'authorization', 'cookie', 'accesstoken', 'refreshtoken', 'clientsecret',
        'bottoken', 'cpf', 'cnpj', 'rg', 'phone', 'telefone', 'email'
      ) then
        return true;
      end if;

      if public.contem_dado_sensivel(valor) then
        return true;
      end if;
    end loop;

    return false;
  end if;

  if jsonb_typeof(dados) = 'array' then
    for item in select * from jsonb_array_elements(dados) loop
      if public.contem_dado_sensivel(item) then
        return true;
      end if;
    end loop;

    return false;
  end if;

  if jsonb_typeof(dados) = 'string' then
    return dados #>> '{}' ~* '(bearer\s+[a-z0-9._~+/-]{16,})'
        or dados #>> '{}' ~ '(^|[^0-9])[0-9]{5,16}:[A-Za-z0-9_-]{30,}'
        or dados #>> '{}' ~ 'sk-[A-Za-z0-9_-]{16,}'
        or dados #>> '{}' ~ 'sb_secret_[A-Za-z0-9_-]{16,}'
        or dados #>> '{}' ~ 'gh[pousr]_[A-Za-z0-9]{16,}'
        or dados #>> '{}' ~ 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'
        or dados #>> '{}' ~ '-----BEGIN [A-Z ]*PRIVATE KEY-----'
        or dados #>> '{}' ~* 'api[_-]?key=[A-Za-z0-9_-]{8,}'
        or dados #>> '{}' ~ '(^|[^0-9])[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}([^0-9]|$)'
        or dados #>> '{}' ~ '(^|[^0-9])[0-9]{2}\.[0-9]{3}\.[0-9]{3}/[0-9]{4}-[0-9]{2}([^0-9]|$)';
  end if;

  return false;
end;
$$;

revoke execute on function public.contem_dado_sensivel(jsonb) from anon, authenticated, public;

comment on function public.contem_dado_sensivel(jsonb) is
  'Barra credencial e documento em colunas jsonb. Usada em CHECK constraints.';

-- ---------------------------------------------------------------------------
-- fontes: de onde as ofertas vem. As reguas de qualidade moram em configuracao.
-- ---------------------------------------------------------------------------
create table public.fontes (
  id bigint primary key generated always as identity,
  slug text not null unique
    constraint fontes_slug_ck check (slug ~ '^[a-z0-9][a-z0-9_-]{2,79}$'),
  nome text not null
    constraint fontes_nome_ck check (char_length(nome) between 1 and 160),
  plataforma text not null
    constraint fontes_plataforma_ck check (plataforma in (
      'mercado_livre', 'shopee', 'kabum', 'amazon', 'manual', 'outro'
    )),
  tipo_fonte text not null
    constraint fontes_tipo_ck check (tipo_fonte in (
      'api_oficial', 'portal_afiliado', 'importacao_manual', 'feed_parceiro'
    )),
  url_base text
    constraint fontes_url_base_ck check (url_base is null or url_base ~ '^https://'),
  nome_segredo text
    constraint fontes_nome_segredo_ck check (
      nome_segredo is null or nome_segredo ~ '^[a-z0-9][a-z0-9_]{2,79}$'
    ),
  configuracao jsonb not null default '{}'::jsonb
    constraint fontes_configuracao_objeto_ck check (jsonb_typeof(configuracao) = 'object')
    constraint fontes_configuracao_segura_ck check (not public.contem_dado_sensivel(configuracao)),
  habilitada boolean not null default false,
  intervalo_coleta_segundos integer not null default 900
    constraint fontes_intervalo_ck check (intervalo_coleta_segundos between 60 and 86400),
  coletada_em timestamptz,
  proxima_coleta_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

comment on column public.fontes.nome_segredo is
  'Nome da credencial no cofre. Nunca guarda o segredo em si.';

create index fontes_a_coletar_idx
  on public.fontes (proxima_coleta_em, id)
  where habilitada;

create trigger ao_atualizar_fonte
  before update on public.fontes
  for each row execute function public.toca_atualizado_em();

-- ---------------------------------------------------------------------------
-- ofertas: o produto observado, na versao mais recente.
-- ---------------------------------------------------------------------------
create table public.ofertas (
  id bigint primary key generated always as identity,
  fonte_id bigint not null references public.fontes (id) on delete restrict,
  id_externo text not null
    constraint ofertas_id_externo_ck check (char_length(id_externo) between 1 and 300),
  titulo text not null
    constraint ofertas_titulo_ck check (char_length(titulo) between 1 and 600),
  descricao text
    constraint ofertas_descricao_ck check (descricao is null or char_length(descricao) <= 5000),
  url_canonica text not null
    constraint ofertas_url_canonica_ck check (url_canonica ~ '^https://'),
  url_afiliado text
    constraint ofertas_url_afiliado_ck check (url_afiliado is null or url_afiliado ~ '^https://'),
  url_imagem text
    constraint ofertas_url_imagem_ck check (url_imagem is null or url_imagem ~ '^https://'),
  moeda text not null default 'BRL'
    constraint ofertas_moeda_ck check (moeda ~ '^[A-Z]{3}$'),
  preco_atual numeric(14, 2) not null
    constraint ofertas_preco_atual_ck check (preco_atual > 0),
  preco_original numeric(14, 2)
    constraint ofertas_preco_original_ck check (preco_original is null or preco_original >= preco_atual),
  desconto_percentual numeric(5, 2)
    constraint ofertas_desconto_ck check (desconto_percentual is null or desconto_percentual between 0 and 100),
  codigo_cupom text
    constraint ofertas_cupom_ck check (codigo_cupom is null or char_length(codigo_cupom) between 1 and 100),
  cupom_expira_em timestamptz,
  disponivel boolean not null default true,
  situacao text not null default 'descoberta'
    constraint ofertas_situacao_ck check (situacao in (
      'descoberta', 'elegivel', 'recusada', 'expirada', 'pausada'
    )),
  pontuacao numeric(5, 2)
    constraint ofertas_pontuacao_ck check (pontuacao is null or pontuacao between 0 and 100),
  hash_conteudo text not null default ''
    constraint ofertas_hash_ck check (hash_conteudo ~ '^[a-f0-9]{64}$'),
  payload_origem jsonb not null default '{}'::jsonb
    constraint ofertas_payload_objeto_ck check (jsonb_typeof(payload_origem) = 'object')
    constraint ofertas_payload_seguro_ck check (not public.contem_dado_sensivel(payload_origem)),
  visto_primeiro_em timestamptz not null default now(),
  visto_ultimo_em timestamptz not null default now(),
  expira_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint ofertas_fonte_externo_uk unique (fonte_id, id_externo)
);

create index ofertas_fonte_situacao_idx
  on public.ofertas (fonte_id, situacao, visto_ultimo_em desc);

create index ofertas_elegiveis_idx
  on public.ofertas (pontuacao desc, visto_ultimo_em desc, id)
  include (fonte_id, preco_atual, url_afiliado)
  where situacao = 'elegivel' and disponivel;

create index ofertas_expiracao_idx
  on public.ofertas (expira_em)
  where expira_em is not null;

-- O banco, e nao o coletor, define a versao da oferta.
create function public.oferta_calcula_hash()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.hash_conteudo := encode(
    extensions.digest(
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
      'sha256'
    ),
    'hex'
  );

  return new;
end;
$$;

revoke execute on function public.oferta_calcula_hash() from anon, authenticated, public;

create trigger ao_gravar_oferta_calcula_hash
  before insert or update on public.ofertas
  for each row execute function public.oferta_calcula_hash();

create trigger ao_atualizar_oferta
  before update on public.ofertas
  for each row execute function public.toca_atualizado_em();

-- ---------------------------------------------------------------------------
-- historico_precos: cada observacao de preco, com idempotencia.
-- ---------------------------------------------------------------------------
create table public.historico_precos (
  id bigint primary key generated always as identity,
  oferta_id bigint not null references public.ofertas (id) on delete cascade,
  chave_idempotencia text not null unique
    constraint historico_chave_ck check (char_length(chave_idempotencia) between 1 and 240),
  observado_em timestamptz not null default now(),
  moeda text not null default 'BRL'
    constraint historico_moeda_ck check (moeda ~ '^[A-Z]{3}$'),
  preco numeric(14, 2) not null
    constraint historico_preco_ck check (preco > 0),
  preco_original numeric(14, 2)
    constraint historico_preco_original_ck check (preco_original is null or preco_original >= preco),
  disponivel boolean not null default true,
  codigo_cupom text
    constraint historico_cupom_ck check (codigo_cupom is null or char_length(codigo_cupom) between 1 and 100),
  metadados jsonb not null default '{}'::jsonb
    constraint historico_metadados_objeto_ck check (jsonb_typeof(metadados) = 'object')
    constraint historico_metadados_seguro_ck check (not public.contem_dado_sensivel(metadados)),
  criado_em timestamptz not null default now()
);

create index historico_precos_oferta_idx
  on public.historico_precos (oferta_id, observado_em desc)
  include (preco, preco_original, disponivel);

-- ---------------------------------------------------------------------------
-- Acesso: o painel le, ninguem escreve pelo navegador.
-- As Edge Functions usam service_role, que ignora RLS.
-- ---------------------------------------------------------------------------
alter table public.fontes enable row level security;
alter table public.ofertas enable row level security;
alter table public.historico_precos enable row level security;

create policy "operador ativo le fontes"
  on public.fontes for select to authenticated
  using (public.eh_operador_ativo());

create policy "operador ativo le ofertas"
  on public.ofertas for select to authenticated
  using (public.eh_operador_ativo());

create policy "operador ativo le historico"
  on public.historico_precos for select to authenticated
  using (public.eh_operador_ativo());
