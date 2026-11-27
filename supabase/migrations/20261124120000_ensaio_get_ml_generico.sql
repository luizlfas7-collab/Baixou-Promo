-- O ensaio especifico respondeu a primeira pergunta em 24/11:
--   GET /products/{catalogo}        -> 200, responde normal
--   GET /products/{catalogo}/items  -> 403 PA_UNAUTHORIZED_RESULT_FROM_POLICIES
--                                      blocked_by: PolicyAgent
-- O token esta valido (o 200 prova). O ML fechou, por POLITICA, justamente o
-- endpoint que devolve PRECO. E o mesmo caminho que /items/{id} ja tinha
-- tomado nesta aplicacao. Sem preco nao existe deteccao de queda de preco,
-- entao a leitura do ML inteira depende de achar outra porta.
--
-- Para procurar essa porta eu preciso perguntar varios caminhos, nao um fixo.
-- Dai esta versao generica. SO GET, SO api.mercadolibre.com, so service_role,
-- e o token continua saindo do cofre direto para o cabecalho do pg_net sem
-- passar pelo contexto de ninguem.
--
-- O caminho e checado contra barra inicial e contra `..` de proposito: funcao
-- SECURITY DEFINER que monta URL com texto de fora e um lugar onde descuido
-- vira pedido para outro host com o token em anexo.
create or replace function public.ensaio_get_ml(p_caminho text)
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_token text;
  v_pedido bigint;
begin
  if p_caminho is null or left(p_caminho, 1) <> '/' or p_caminho like '%..%' then
    raise exception 'caminho precisa comecar com / e nao conter ..';
  end if;

  select s.decrypted_secret into v_token
  from vault.decrypted_secrets s
  where s.name = 'baixou_ml_access_token';

  if v_token is null then
    raise exception 'sem baixou_ml_access_token no vault';
  end if;

  select net.http_get(
    url := 'https://api.mercadolibre.com' || p_caminho,
    headers := jsonb_build_object(
      'authorization', 'Bearer ' || v_token,
      'accept', 'application/json'),
    timeout_milliseconds := 15000
  ) into v_pedido;

  return v_pedido;
end;
$function$;

revoke all on function public.ensaio_get_ml(text) from public, anon, authenticated;
grant execute on function public.ensaio_get_ml(text) to service_role;
