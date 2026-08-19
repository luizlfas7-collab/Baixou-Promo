-- Chama o publicador. A URL vem da configuracao e o segredo vem do cofre:
-- nada fica embutido no corpo do job do cron.
create function public.disparar_worker()
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
    url := v_url || '/baixou-worker',
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

revoke execute on function public.disparar_worker() from anon, authenticated, public;

comment on function public.disparar_worker() is
  'Aciona o publicador. Usada pelo pg_cron e util para disparo manual em teste.';

update public.configuracoes
  set url_das_funcoes = 'https://xxskmxhpzbqzxoaffiul.supabase.co/functions/v1'
  where id = 1;
