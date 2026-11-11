-- Ensaio do coletor da Shopee sob demanda.
--
-- POR QUE ISSO EXISTE: desde 05/11 a Shopee acumula falhas de busca, e em
-- 09/11 a media saltou de 2,5 para 11,8 palavras falhando de 20. A tabela
-- execucoes registra o NUMERO ("15 falhas em 20 palavras") e joga fora O
-- MOTIVO: o coletor monta `detalhes` com { palavra, etapa: "buscar", codigo,
-- erro } para cada falha, mas `detalhes` so existe na resposta HTTP, e ninguem
-- guarda a resposta. Resultado: quatro dias sem saber se e limite de taxa,
-- assinatura invalida, credencial vencida ou tempo esgotado — quatro remedios
-- diferentes para o mesmo numero.
--
-- Mesmo padrao de ensaio_coletor_ml(), criado em 01/10 pelo mesmo motivo. O
-- segredo sai do cofre direto para o cabecalho do pg_net: nao passa pelo
-- operador nem aparece em log.
--
-- ATENCAO ao corpo: o coletor da Shopee le `corpo.ensaio === true`, NAO
-- `modo: "ensaio"` como o do ML. Mandar a chave errada faz uma rodada de
-- verdade, que enfileira.
create or replace function public.ensaio_coletor_shopee()
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
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
    url := v_url || '/baixou-coletor-shopee',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-cron-secret', v_segredo
    ),
    body := jsonb_build_object('ensaio', true),
    timeout_milliseconds := 25000
  ) into v_pedido;

  return v_pedido;
end;
$function$;

revoke all on function public.ensaio_coletor_shopee() from public, anon, authenticated;
