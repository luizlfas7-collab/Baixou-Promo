-- Mesmo desenho de disparar_worker: a URL vem da configuracao e o segredo vem
-- do cofre, para que restaurar o banco em outro projeto nao chame as funcoes
-- do projeto antigo em silencio.
create function public.disparar_coletor_ml()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_segredo text;
  v_pedido bigint;
begin
  select url_das_funcoes into v_url from public.configuracoes where id = 1;

  if v_url is null or v_url = '' then
    raise exception 'url_das_funcoes nao configurada' using errcode = 'P0002';
  end if;

  select decrypted_secret into v_segredo
  from vault.decrypted_secrets
  where name = 'baixou_worker_cron_secret';

  if v_segredo is null then
    raise exception 'Segredo baixou_worker_cron_secret nao existe no cofre'
      using errcode = 'P0002';
  end if;

  select net.http_post(
    url := v_url || '/baixou-coletor-ml',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-cron-secret', v_segredo
    ),
    body := jsonb_build_object('trigger', 'cron', 'requested_at', now()),
    timeout_milliseconds := 25000
  ) into v_pedido;

  return v_pedido;
end;
$$;

revoke execute on function public.disparar_coletor_ml() from anon, authenticated, public;

comment on function public.disparar_coletor_ml() is
  'Aciona o coletor do Mercado Livre. Usada pelo pg_cron e util para disparo manual em teste.';
