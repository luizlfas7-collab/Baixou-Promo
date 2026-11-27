-- Ensaio do coletor do ML sob demanda.
--
-- POR QUE ISSO EXISTE: o coletor do ML recusou 10 de 10 itens por tres dias
-- seguidos e a tabela execucoes registrou apenas "recusados: 10", sem um unico
-- motivo. O coletor SABE o motivo de cada recusa — ele monta `detalhes` com
-- situacao, pontuacao e componentes por item — mas joga esse diagnostico fora,
-- porque `detalhes` so vai na resposta HTTP e ninguem guarda a resposta.
--
-- Esta funcao pede uma rodada em modo ensaio e devolve o id do pedido pg_net,
-- cuja resposta (com os `detalhes`) fica legivel em net._http_response. Ensaio
-- observa, pontua e relata mas NUNCA enfileira: nao existe caminho daqui ate
-- uma publicacao, por isso roda em producao sem risco de soltar post no canal.
create or replace function public.ensaio_coletor_ml()
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
    url := v_url || '/baixou-coletor-ml',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-cron-secret', v_segredo
    ),
    -- `modo: ensaio` e a chave que o index.ts le (corpo.modo === "ensaio").
    body := jsonb_build_object('modo', 'ensaio', 'trigger', 'diagnostico'),
    timeout_milliseconds := 25000
  ) into v_pedido;

  return v_pedido;
end;
$function$;

revoke all on function public.ensaio_coletor_ml() from public, anon, authenticated;
