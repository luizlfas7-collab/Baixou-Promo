-- ---------------------------------------------------------------------------
-- O disparo da Shopee passa pelo portao do gateway.
--
-- O coletor do ML roda com verify_jwt desligado: o portao deixa entrar e quem
-- autoriza de fato e o x-cron-secret, conferido dentro da funcao. A funcao da
-- Shopee subiu com verify_jwt LIGADO e o gateway devolveu 401 antes de o
-- codigo existir.
--
-- Contorno: mandar tambem a chave anon, que e publicavel por definicao — o
-- portao so quer um JWT valido. A autorizacao real nao muda de lugar: continua
-- sendo o x-cron-secret, que nenhum cliente anonimo tem.
--
-- Isto e contorno, nao destino. O certo e desligar verify_jwt na funcao, para
-- ficar igual ao coletor do ML; enquanto houver dois jeitos de autorizar o
-- mesmo tipo de disparo, alguem vai copiar o errado.
--
-- Tambem se alinha ao ML no resto: url vinda de configuracoes.url_das_funcoes
-- em vez de cravada no corpo, e timeout explicito.
-- ---------------------------------------------------------------------------

create or replace function public.disparar_coletor_shopee()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_segredo text;
  v_pedido bigint;
  v_anon constant text :=
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inh4c2tteGhwemJxenhvYWZmaXVsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY5MDg3MzUsImV4cCI6MjEwMjQ4NDczNX0.p3Vgx7RHJLWlD19JKHLf4EQAnLWqcQB9J96FNakDWvg';
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
    url := v_url || '/baixou-coletor-shopee',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'Authorization', 'Bearer ' || v_anon,
      'x-cron-secret', v_segredo
    ),
    body := jsonb_build_object('trigger', 'cron', 'requested_at', now()),
    timeout_milliseconds := 25000
  ) into v_pedido;

  return v_pedido;
end;
$$;

comment on function public.disparar_coletor_shopee() is
  'Aciona baixou-coletor-shopee. Manda a chave anon so para passar o verify_jwt do gateway; quem autoriza e o x-cron-secret.';

revoke all on function public.disparar_coletor_shopee() from public, anon, authenticated;
grant execute on function public.disparar_coletor_shopee() to service_role;
