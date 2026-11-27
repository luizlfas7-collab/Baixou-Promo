-- "Resolva esse motor cego pelo ML" — o dono, 26/11.
--
-- NAO DA PARA RESOLVER DO NOSSO LADO, e a investigacao abaixo e a prova. O que
-- da, e o que esta migracao faz, e trocar "cego, motivo desconhecido" por
-- "cego, 403 PA_UNAUTHORIZED, confirmado ha N minutos" — e detectar a volta
-- sozinho, em 10 minutos, sem ninguem olhando.
--
-- O QUE FOI TESTADO em 26/11, com o token do cofre indo direto ao cabecalho:
--
--   GET /users/me                      200   token integro, conta reconhecida
--   GET /products/{catalogo}           200   titulo, fotos, atributos, pickers
--   GET /products/search?site_id=MLB   200   busca de catalogo
--   GET /highlights/MLB/category/{id}  200   so ids e posicoes
--   GET /products/{catalogo}/items     403   PA_UNAUTHORIZED, PolicyAgent
--   GET /items/{id}                    403   access_denied
--   GET /items?ids={id}                403   access_denied no item do lote
--   GET /sites/MLB/search?q=           403   forbidden
--   GET /reviews/item/{id}             403   forbidden
--
-- O MESMO TOKEN que le /users/me com 200 recebe 403 em tudo que tem preco.
-- Logo nao e credencial: e politica sobre o RECURSO. E dentro do acesso que a
-- aplicacao tem hoje nao existe nenhum caminho com preco — /products/{catalogo}
-- traz 13,8 KB e nenhuma chave `price`, com buy_box_winner nulo e pickers que
-- so tem cor, foto e nome. Sem preco nao existe deteccao de queda de preco.
--
-- De quebra: /reviews/item/ tambem caiu, ou seja lerAvaliacao() do ML morreu
-- junto. Quando o acesso voltar, conferir as duas coisas, nao so o preco.
--
-- POR QUE UMA SONDA, E NAO SO O VEREDITO `cega`: `cega` diz que nao houve
-- leitura. Nao diz POR QUE, nem desde quando com precisao, nem avisa quando
-- muda de 403 para 401 (credencial) ou para 200 (voltou). Durante o incidente
-- eu descobri o 403 a mao, tres vezes, porque nada registrava. Dado medido que
-- ninguem guarda e a forma mais comum de guarda que nao dispara neste projeto.
--
-- DUAS FASES, porque pg_net e assincrono: a chamada e disparada numa execucao
-- e a resposta e lida na seguinte. Tentar ler na mesma transacao devolve nada
-- — ja me custou uma rodada de diagnostico em 24/11.
--
-- NUNCA APONTAR A SONDA PARA /users/me: aquele endpoint devolve nome, CPF,
-- endereco e telefone do dono. A sonda tem que bater num recurso de catalogo,
-- que nao tem dado pessoal, porque o corpo da resposta fica gravado aqui.
create table if not exists public.acesso_fonte (
  fonte_id        bigint primary key references public.fontes(id) on delete cascade,
  caminho         text not null,
  pedido_id       bigint,
  status_code     integer,
  codigo          text,
  mensagem        text,
  verificado_em   timestamptz,
  bloqueado_desde timestamptz,
  atualizado_em   timestamptz not null default now()
);

comment on table public.acesso_fonte is
  'Sonda de acesso por fonte: guarda o ultimo codigo HTTP que a API da fonte devolveu num recurso essencial, e desde quando esta bloqueado. Existe porque o veredito `cega` diz que nao ha leitura mas nao diz por que. NUNCA apontar o caminho para endpoint com dado pessoal: o corpo fica gravado.';

alter table public.acesso_fonte enable row level security;
revoke all on table public.acesso_fonte from anon, authenticated;
grant all on table public.acesso_fonte to service_role;

insert into public.acesso_fonte (fonte_id, caminho)
select f.id, '/products/MLB45880631/items'
from public.fontes f
where f.slug = 'mercado_livre_api_oficial'
on conflict (fonte_id) do nothing;

-- ---------------------------------------------------------------------------
create or replace function public.sondar_acesso_ml()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_fonte       bigint;
  v_caminho     text;
  v_pendente    bigint;
  v_status      integer;
  v_corpo       text;
  v_erro        text;
  v_codigo      text;
  v_bloqueado   timestamptz;
  v_novo_pedido bigint;
  v_mudou       text := 'sem_resposta_ainda';
begin
  select a.fonte_id, a.caminho, a.pedido_id, a.bloqueado_desde
    into v_fonte, v_caminho, v_pendente, v_bloqueado
  from public.acesso_fonte a
  join public.fontes f on f.id = a.fonte_id
  where f.slug = 'mercado_livre_api_oficial';

  if v_fonte is null then
    return jsonb_build_object('erro', 'sonda_nao_cadastrada');
  end if;

  -- FASE 1: ler o que a chamada anterior respondeu.
  if v_pendente is not null then
    select r.status_code, left(r.content, 300), r.error_msg
      into v_status, v_corpo, v_erro
    from net._http_response r
    where r.id = v_pendente;

    if v_status is not null or v_erro is not null then
      -- O codigo que a propria API usa, quando ela manda um. Guardar o codigo
      -- e nao so o numero HTTP foi o que separou "politica de acesso" de
      -- "credencial vencida" neste incidente.
      v_codigo := coalesce(
        substring(v_corpo from '"code"\s*:\s*"([A-Za-z0-9_]+)"'),
        substring(v_corpo from '"error"\s*:\s*"([A-Za-z0-9_ ]+)"'),
        case when v_erro is not null then 'erro_de_rede' end
      );

      if coalesce(v_status, 0) = 200 then
        if v_bloqueado is not null then v_mudou := 'liberou'; else v_mudou := 'segue_ok'; end if;
        v_bloqueado := null;
      else
        if v_bloqueado is null then
          v_mudou := 'bloqueou';
          v_bloqueado := now();
        else
          v_mudou := 'segue_bloqueado';
        end if;
      end if;

      update public.acesso_fonte
         set status_code = v_status,
             codigo = v_codigo,
             mensagem = left(coalesce(v_erro, v_corpo), 300),
             verificado_em = now(),
             bloqueado_desde = v_bloqueado,
             atualizado_em = now()
       where fonte_id = v_fonte;
    end if;
  end if;

  -- FASE 2: disparar a proxima.
  begin
    v_novo_pedido := public.ensaio_get_ml(v_caminho);
  exception when others then
    v_novo_pedido := null;
  end;

  update public.acesso_fonte
     set pedido_id = v_novo_pedido, atualizado_em = now()
   where fonte_id = v_fonte;

  return jsonb_build_object(
    'caminho', v_caminho,
    'status', v_status,
    'codigo', v_codigo,
    'bloqueado_desde', v_bloqueado,
    'transicao', v_mudou
  );
end;
$function$;

revoke all on function public.sondar_acesso_ml() from public, anon, authenticated;
grant execute on function public.sondar_acesso_ml() to service_role;

-- ---------------------------------------------------------------------------
-- Guarda para o vigia. Quinze minutos para nao gritar em soluco de rede.
create or replace function public.acesso_bloqueado()
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'chave', 'acesso:' || d.slug,
           'texto', format(
             'ACESSO NEGADO NA FONTE: %s responde HTTP %s (%s) em %s desde %s, ou seja ha %s. Sem esse recurso a fonte nao le preco e nao ha deteccao de queda. Isso NAO se resolve por codigo: e politica de acesso da plataforma. Ultima verificacao: %s.',
             d.slug, d.status_code, coalesce(d.codigo, 'sem codigo'), d.caminho,
             to_char(d.bloqueado_desde, 'DD/MM HH24:MI'),
             justify_hours(date_trunc('minute', now() - d.bloqueado_desde)),
             to_char(d.verificado_em, 'DD/MM HH24:MI'))
         )), '[]'::jsonb)
  from (
    select f.slug, a.caminho, a.status_code, a.codigo,
           a.bloqueado_desde, a.verificado_em
    from public.acesso_fonte a
    join public.fontes f on f.id = a.fonte_id
    where a.bloqueado_desde is not null
      and a.bloqueado_desde < now() - interval '15 minutes'
  ) d;
$function$;

revoke all on function public.acesso_bloqueado() from public, anon;
grant execute on function public.acesso_bloqueado() to service_role, authenticated;

-- ---------------------------------------------------------------------------
-- A cada 10 minutos. Duas chamadas por hora e irrisorio contra as ~600 que o
-- coletor ja faz, e e o que garante que a volta do acesso seja percebida em
-- 10 minutos em vez de no proximo boletim.
select cron.schedule('baixou-sonda-acesso', '*/10 * * * *',
                     $cron$select public.sondar_acesso_ml();$cron$);
