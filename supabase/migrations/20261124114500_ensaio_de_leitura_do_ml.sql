-- POR QUE ESTE ENSAIO EXISTE.
--
-- 23/11 17:22 UTC o ML parou de ler. Toda rodada desde entao: `falhou`, com
-- `recusas_por_motivo: {falha_ler: 10}` — os dez itens da rodada falhando na
-- etapa `ler`. O vigia fez o trabalho dele e alertou as 17:43, 21 minutos
-- depois. O token esta `pronta`, geracao 351, renovando de 6 em 6 horas.
-- Nao e credencial.
--
-- E EU NAO CONSEGUIA SABER O MOTIVO. O coletor publicado registra so o
-- agregado ("falhas: 10"); o codigo HTTP de cada falha so entra no registro
-- na versao que esta no repo e nao foi publicada. Mesmo buraco que fez o
-- "error [10000]" da Shopee passar seis dias parecendo recusa de produto.
--
-- Entao a pergunta — o ML responde o que? — se faz direto, com o token
-- saindo do cofre para o cabecalho do pg_net sem passar pelo contexto de
-- ninguem. Mesmo padrao do ensaio_coletor_shopee de 11/11.
--
-- As DUAS chamadas que lerAnuncioDoCatalogo() faz por item, na mesma ordem:
--   GET /products/{catalogo}         -> titulo e foto
--   GET /products/{catalogo}/items   -> precos dos anuncios do catalogo
-- O /items/{id} direto ja responde 403 nesta aplicacao desde sempre. Se o ML
-- tiver fechado /products tambem, o unico caminho de leitura do ML morreu, e
-- isso e estrutural, nao transitorio. Este ensaio responde qual dos dois.
--
-- SO LE. Nao grava oferta, nao enfileira, nao mexe em itens_ml, e por isso
-- nao conta como rodada nem suja a metrica de saude.
create or replace function public.ensaio_ler_catalogo_ml(
  p_catalogo text default 'MLB75083898'
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_token text;
  v_produto bigint;
  v_itens   bigint;
begin
  select s.decrypted_secret into v_token
  from vault.decrypted_secrets s
  where s.name = 'baixou_ml_access_token';

  if v_token is null then
    return jsonb_build_object('erro', 'sem_baixou_ml_access_token_no_vault');
  end if;

  select net.http_get(
    url := 'https://api.mercadolibre.com/products/' || p_catalogo,
    headers := jsonb_build_object(
      'authorization', 'Bearer ' || v_token,
      'accept', 'application/json'),
    timeout_milliseconds := 15000
  ) into v_produto;

  select net.http_get(
    url := 'https://api.mercadolibre.com/products/' || p_catalogo || '/items',
    headers := jsonb_build_object(
      'authorization', 'Bearer ' || v_token,
      'accept', 'application/json'),
    timeout_milliseconds := 15000
  ) into v_itens;

  return jsonb_build_object(
    'catalogo', p_catalogo,
    'pedido_produto', v_produto,
    'pedido_itens', v_itens
  );
end;
$function$;

revoke all on function public.ensaio_ler_catalogo_ml(text) from public, anon, authenticated;
grant execute on function public.ensaio_ler_catalogo_ml(text) to service_role;
