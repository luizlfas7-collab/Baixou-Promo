-- ---------------------------------------------------------------------------
-- O terreno da Shopee: credencial, vantagem generica e disparo.
--
-- Nao liga nada. A fonte continua desabilitada e o job nasce inativo. O que
-- este arquivo faz e deixar de existir diferenca entre "o coletor da Shopee
-- nao roda" e "o coletor da Shopee nao existe" — a partir daqui so falta a
-- chave e o deploy da funcao.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. A credencial
--
-- A Open API de afiliados da Shopee assina cada chamada com DOIS valores:
-- um App ID e um App Secret. Ficam juntos num segredo so do Vault, em JSON,
-- porque separados abrem a porta para o par dessincronizar — girar um e
-- esquecer o outro deixaria a assinatura invalida sem nada apontar o motivo.
--
-- A funcao devolve situacao em vez de estourar: coletor que recebe
-- 'sem_credencial' registra a rodada e explica; coletor que recebe excecao
-- morre antes de registrar, e rodada nao registrada e rodada invisivel.
-- ---------------------------------------------------------------------------

create or replace function public.shopee_credenciais_ler()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_bruto text;
  v_json jsonb;
begin
  select s.decrypted_secret into v_bruto
  from vault.decrypted_secrets s
  where s.name = 'shopee_afiliados';

  if v_bruto is null then
    return jsonb_build_object('situacao', 'sem_credencial',
      'motivo', 'O segredo shopee_afiliados nao existe no Vault');
  end if;

  begin
    v_json := v_bruto::jsonb;
  exception when others then
    return jsonb_build_object('situacao', 'credencial_invalida',
      'motivo', 'O segredo shopee_afiliados nao e JSON');
  end;

  if coalesce(v_json ->> 'app_id', '') = '' or coalesce(v_json ->> 'secret', '') = '' then
    return jsonb_build_object('situacao', 'credencial_invalida',
      'motivo', 'O JSON precisa ter app_id e secret preenchidos');
  end if;

  return jsonb_build_object(
    'situacao', 'pronta',
    'app_id', v_json ->> 'app_id',
    'secret', v_json ->> 'secret'
  );
end;
$$;

comment on function public.shopee_credenciais_ler() is
  'App ID e Secret da Open API de afiliados da Shopee. Devolve situacao em vez de estourar.';

revoke all on function public.shopee_credenciais_ler() from public, anon, authenticated;
grant execute on function public.shopee_credenciais_ler() to service_role;

-- ---------------------------------------------------------------------------
-- 2. A vantagem de preco nunca foi do Mercado Livre
--
-- ml_vantagem_de_preco() so le historico_precos por oferta_id. O prefixo 'ml_'
-- e heranca do dia em que so existia uma fonte, e nome que mente atrapalha:
-- daqui a um mes alguem lendo o coletor da Shopee chamar 'ml_' vai parar para
-- checar se aquilo esta certo.
--
-- Alias, nao renomeacao: o coletor do ML em producao chama pelo nome antigo, e
-- trocar a assinatura sob um coletor que esta rodando e como trocar o pneu com
-- o carro andando. Os dois nomes valem; o novo e o que se usa daqui para a
-- frente.
-- ---------------------------------------------------------------------------

create or replace function public.vantagem_de_preco(p_oferta_id bigint)
returns jsonb
language sql
security definer
set search_path to ''
as $$
  select public.ml_vantagem_de_preco(p_oferta_id);
$$;

comment on function public.vantagem_de_preco(bigint) is
  'Competitividade da oferta contra o proprio historico. Serve qualquer fonte; ml_vantagem_de_preco e o nome antigo.';

revoke all on function public.vantagem_de_preco(bigint) from public, anon;
grant execute on function public.vantagem_de_preco(bigint) to service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 3. O disparo
--
-- Mesmo desenho do coletor do ML: pg_net chama a Edge Function com o segredo
-- do cron no cabecalho. A funcao nasce declarada aqui, e nao a mao, porque
-- agendamento que so existe no banco some no proximo restore — foi a licao da
-- migracao 20260902020000.
-- ---------------------------------------------------------------------------

create or replace function public.disparar_coletor_shopee()
returns bigint
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_url text;
  v_segredo text;
  v_pedido bigint;
begin
  select s.decrypted_secret into v_segredo
  from vault.decrypted_secrets s
  where s.name = 'baixou_worker_cron_secret';

  if v_segredo is null then
    raise exception 'Segredo do cron ausente no Vault';
  end if;

  v_url := 'https://xxskmxhpzbqzxoaffiul.supabase.co/functions/v1/baixou-coletor-shopee';

  select net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-cron-secret', v_segredo
    ),
    body := '{}'::jsonb
  ) into v_pedido;

  return v_pedido;
end;
$$;

comment on function public.disparar_coletor_shopee() is
  'Aciona a Edge Function baixou-coletor-shopee com o segredo do cron.';

revoke all on function public.disparar_coletor_shopee() from public, anon, authenticated;
grant execute on function public.disparar_coletor_shopee() to service_role;

-- ---------------------------------------------------------------------------
-- 4. O agendamento, desligado
--
-- Nasce inativo de proposito. Ligar e um ato deliberado do dono, depois de a
-- chave estar no Vault e de a primeira chamada de teste passar. Coletor que
-- comeca a rodar sozinho contra uma API que ninguem validou gera erro em
-- volume antes de alguem olhar.
--
-- A cada 15 min: e o intervalo que a propria fonte declara em
-- intervalo_coleta_segundos (900), e busca por palavra-chave nao tem urgencia
-- de revisita como a watchlist do ML tem.
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from cron.job where jobname = 'baixou-coletor-shopee') then
    perform cron.unschedule('baixou-coletor-shopee');
  end if;
end;
$$;

-- Minutos 7, 23, 37 e 53: todos IMPARES, de proposito.
--
-- Nao existe minuto livre neste banco — o coletor do ML ocupa os pares e o
-- worker os impares. Um terceiro job nao tem como nao colidir com alguem, so
-- tem como escolher com quem. Escolhe o worker: ele faz uma chamada ao
-- Telegram por rodada, enquanto o coletor do ML abre a credencial e le dez
-- itens, e foi a disputa com ele que custou 4,9% das rodadas em 20260902100000.
--
-- Exposicao: 4 minutos por hora em vez dos 30 daquele episodio.
select cron.schedule(
  'baixou-coletor-shopee',
  '7,23,37,53 * * * *',
  $$select public.disparar_coletor_shopee()$$
);
select cron.alter_job(
  (select jobid from cron.job where jobname = 'baixou-coletor-shopee'),
  active => false
);
