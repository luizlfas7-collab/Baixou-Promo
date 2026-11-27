-- Credenciais da Shopee e a rodada do coletor
--
-- A Shopee nao tem OAuth: nao ha token que expira, nem refresh rotativo, nem
-- lease para impedir duas renovacoes simultaneas. Sao dois segredos fixos —
-- `app_id` e `app_secret` — e cada chamada e assinada na hora. Toda a maquina
-- de `credenciais_ml` nao tem equivalente aqui, e isso e uma boa noticia: o
-- que nao existe nao quebra as 6 horas.
--
-- Os segredos moram no cofre, como todos os outros. `app_id` tambem, e nao em
-- `fontes.configuracao`: ele nao e secreto sozinho, mas o CHECK
-- `contem_dado_sensivel()` recusaria a linha de qualquer jeito, e manter os
-- dois juntos evita a duvida de qual estava onde.

create or replace function public.shopee_credenciais()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_app_id text;
  v_secret text;
  v_url_base text;
begin
  select decrypted_secret into v_app_id
  from vault.decrypted_secrets where name = 'baixou_shopee_app_id';

  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'baixou_shopee_app_secret';

  select f.url_base into v_url_base
  from public.fontes f where f.slug = 'shopee_open_api';

  if v_app_id is null or v_secret is null then
    return jsonb_build_object(
      'ok', false,
      'motivo', 'credenciais_ausentes',
      'detalhe', 'Faltam baixou_shopee_app_id e/ou baixou_shopee_app_secret no cofre.'
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'app_id', v_app_id,
    'app_secret', v_secret,
    'url_base', coalesce(v_url_base, 'https://open-api.affiliate.shopee.com.br')
  );
end;
$$;

comment on function public.shopee_credenciais() is
  'Credenciais da Open API de afiliados da Shopee, do cofre. Devolve segredo: so o service_role executa.';

-- Segredo de verdade sai do alcance de quem so tem sessao no navegador.
revoke all on function public.shopee_credenciais() from public, anon, authenticated;
grant execute on function public.shopee_credenciais() to service_role;

-- ---------------------------------------------------------------------------
-- Saude da conexao, sem vazar o segredo
--
-- `shopee_credenciais()` nao serve para diagnostico: ela devolve o secret. Esta
-- aqui responde a unica pergunta que o operador precisa fazer no dia a dia.
-- ---------------------------------------------------------------------------

create or replace function public.shopee_conexao_estado()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select jsonb_build_object(
    'app_id_no_cofre', exists (
      select 1 from vault.decrypted_secrets where name = 'baixou_shopee_app_id'
    ),
    'secret_no_cofre', exists (
      select 1 from vault.decrypted_secrets where name = 'baixou_shopee_app_secret'
    ),
    'fonte_habilitada', coalesce(
      (select f.habilitada from public.fontes f where f.slug = 'shopee_open_api'), false
    ),
    'itens_na_watchlist', (
      select count(*) from public.itens_ml where plataforma = 'shopee' and habilitado
    ),
    'ultima_coleta', (
      select f.coletada_em from public.fontes f where f.slug = 'shopee_open_api'
    )
  );
$$;

comment on function public.shopee_conexao_estado() is
  'A Shopee esta conectada e coletando? Responde sem devolver segredo nenhum.';

revoke all on function public.shopee_conexao_estado() from public, anon;
grant execute on function public.shopee_conexao_estado() to service_role, authenticated;

-- ---------------------------------------------------------------------------
-- Carimbo de rodada da fonte
--
-- O ML marca isto pela watchlist (`proxima_observacao_em` por linha). A Shopee
-- descobre por palavra-chave, entao o ritmo e da FONTE e nao do item.
-- ---------------------------------------------------------------------------

create or replace function public.fonte_coletada(p_slug text)
returns void
language sql
security definer
set search_path to ''
as $$
  update public.fontes
  set coletada_em = now(),
      proxima_coleta_em = now() + make_interval(secs => intervalo_coleta_segundos),
      atualizado_em = now()
  where slug = p_slug;
$$;

comment on function public.fonte_coletada(text) is
  'Carimba a rodada da fonte. Para coletor que varre por palavra-chave, o ritmo e da fonte, nao do item.';

revoke all on function public.fonte_coletada(text) from public, anon, authenticated;
grant execute on function public.fonte_coletada(text) to service_role;
