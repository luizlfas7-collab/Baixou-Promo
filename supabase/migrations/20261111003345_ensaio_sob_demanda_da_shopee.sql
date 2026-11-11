-- Ensaio do coletor da Shopee sob demanda.
--
-- POR QUE ISSO EXISTE: de 05 a 11/11 a Shopee acumulou falhas de busca e em
-- 09/11 a media saltou de 2,5 para 11,8 palavras falhando de 20. A tabela
-- execucoes registrava o NUMERO ("15 falhas em 20 palavras") e jogava fora O
-- MOTIVO: o coletor monta `detalhes` com { palavra, etapa, codigo, erro } para
-- cada falha, mas `detalhes` so existe na resposta HTTP, e ninguem guarda a
-- resposta. Seis dias sem saber se era limite de taxa, assinatura invalida,
-- credencial vencida ou tempo esgotado — quatro remedios para o mesmo numero.
-- Com esta funcao a resposta foi lida em minutos: "error [10000]: System
-- Error", aleatorio, variando de palavra a cada rodada.
--
-- Mesmo padrao de ensaio_coletor_ml(), criado em 01/10 pelo mesmo motivo. O
-- segredo sai do cofre direto para o cabecalho do pg_net: nao passa pelo
-- operador nem aparece em log.
--
-- Esta versao e o resultado de tres tentativas, todas registradas no ledger do
-- banco (20261111003036, 20261111003140, 20261111003345): a primeira tomou 401
-- por faltar o cabecalho Authorization (a funcao da Shopee ainda exige
-- verify_jwt) e a segunda estourou o tempo, porque a rodada leva ~60s e o
-- limite estava em 25s.
create or replace function public.ensaio_coletor_shopee()
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_url text;
  v_segredo text;
  v_anon text;
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

  -- A chave anon sai da definicao de disparar_coletor_shopee(): UMA fonte da
  -- verdade. Uma segunda copia do literal seria mais uma coisa para divergir, e
  -- e exatamente a classe de defeito que ja custou dias aqui. Quando verify_jwt
  -- for desligado (pendencia do dono), as duas funcoes param de precisar da
  -- chave e este extrator pode sair.
  v_anon := substring(
    pg_get_functiondef('public.disparar_coletor_shopee()'::regprocedure)
    from 'eyJ[A-Za-z0-9_.-]+');

  if v_anon is null then
    raise exception 'Nao achei a chave anon em disparar_coletor_shopee()'
      using errcode = 'P0002';
  end if;

  select net.http_post(
    url := v_url || '/baixou-coletor-shopee',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'Authorization', 'Bearer ' || v_anon,
      'x-cron-secret', v_segredo
    ),
    -- O coletor da Shopee le `corpo.ensaio === true`, NAO `modo: "ensaio"`
    -- como o do ML. Chave errada aqui faz uma rodada de verdade, que enfileira.
    body := jsonb_build_object('ensaio', true),
    -- 120s: a rodada leva ~60s (medido 57 a 105s entre 26/10 e 11/11).
    timeout_milliseconds := 120000
  ) into v_pedido;

  return v_pedido;
end;
$function$;

revoke all on function public.ensaio_coletor_shopee() from public, anon, authenticated;
