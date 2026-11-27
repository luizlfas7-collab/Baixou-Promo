-- O MERCADO LIVRE DEIXOU DE SER FONTE DE PRECO, E ISSO NAO E DESTA APLICACAO.
--
-- PROVA DE TERCEIRO, que e o que fecha o caso. O projeto publico
-- Maxwbh/Lista_de_Presentes abriu o issue #60 em 24/11/2026 com logs de
-- 23/11/2026 22:29 a 22:33 registrando, em NOVE catalogos diferentes:
--
--   "Falha ao consultar /products/MLB45023857/items (HTTP 403)"
--   "code":"PA_UNAUTHORIZED_RESULT_FROM_POLICIES"
--   "blocked_by":"PolicyAgent"
--
-- e o sintoma "Titulo: True, Preco: None, Imagem: True" — identico ao nosso.
-- Outra aplicacao, outro dono, outro codigo, MESMO endpoint, MESMO erro,
-- MESMO dia. Nao e permissao, nao e certificacao, nao e credencial desta
-- conta: o ML fechou /products/{catalogo}/items para todos em 23/11/2026.
--
-- Era o ultimo endpoint com preco de terceiros. Outros projetos ja
-- documentavam /items/{id}, /items?ids=, /items/{id}/prices e
-- /sites/MLB/search em 403 antes disso, usando /products/{id}/items como a
-- saida que restava. Foi essa que caiu.
--
-- QUINZE ENDPOINTS TESTADOS daqui, nenhum devolve preco:
--   200 sem preco: /users/me, /users/{id}, /users/{id}/items/search,
--                  /applications/{id}, /sites/MLB, /products/{cat},
--                  /products/search, /highlights/MLB/category/{id},
--                  /highlights/MLB/item/{id}, /trends/MLB,
--                  /sites/MLB/domain_discovery/search
--   403:           /products/{cat}/items (com e sem parametros), /items/{id},
--                  /items?ids=, /sites/MLB/search?q=, /reviews/item/{id}
--   500: /products/{cat}/prices    404: /catalog_listings/{cat}
--
-- O QUE ESTA MIGRACAO FAZ, e por que.
--
-- 1. DESLIGA a fonte. Mantida ligada, ela queima ~14.400 chamadas por dia
--    para receber 403, contra uma plataforma de quem ainda queremos favor, e
--    mantem DOIS alarmes acesos para sempre (motor cego e fonte muda).
--    Alarme permanentemente aceso nao informa nada e ensina o dono a ignorar
--    o painel — e o defeito que este projeto mais combate.
--
-- 2. O ALARME NAO SOME. acesso_bloqueado() le acesso_fonte e NAO filtra por
--    fonte habilitada, entao continua dizendo "403 PolicyAgent desde 23/11
--    17:22" a cada ciclo. Trocamos dois alarmes vagos e permanentes por um
--    preciso. A sonda segue rodando de 10 em 10 minutos.
--
-- 3. VOLTA SOZINHA. Quando a sonda vir 200, sondar_acesso_ml() RELIGA a fonte
--    no mesmo instante e registra em `erros` para aparecer no boletim. Sem
--    depender de alguem perceber. Se o ML reabrir as 3 da manha de um domingo,
--    a coleta recomeca as 3h10.
--
-- 4. Remove a chave `entrega:mercado_livre_api_oficial` ANTES de desligar.
--    Sem isso o vigia mandaria "NORMALIZADO apos 4 dias: FONTE MUDA..." e o
--    dono leria que o ML voltou. O alarme nao foi resolvido: foi substituido.
--    Mesmo cuidado de 26/11 com a chave `fonte:`.

select public.alerta_resolvido('entrega:mercado_livre_api_oficial');

update public.fontes
   set habilitada = false
 where slug = 'mercado_livre_api_oficial';

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
  v_religada    boolean := false;
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
      v_codigo := coalesce(
        substring(v_corpo from '"code"\s*:\s*"([A-Za-z0-9_]+)"'),
        substring(v_corpo from '"error"\s*:\s*"([A-Za-z0-9_ ]+)"'),
        case when v_erro is not null then 'erro_de_rede' end
      );

      if coalesce(v_status, 0) = 200 then
        if v_bloqueado is not null then
          v_mudou := 'liberou';

          -- RELIGA a fonte no mesmo instante. Desligar foi consequencia do
          -- bloqueio; religar tem que ser consequencia da liberacao, sem
          -- depender de alguem perceber e sem esperar o boletim.
          update public.fontes
             set habilitada = true
           where id = v_fonte and not habilitada;

          v_religada := found;

          if v_religada then
            insert into public.erros (
              chave_idempotencia, gravidade, codigo, mensagem, contexto,
              ocorrencias, visto_primeiro_em, visto_ultimo_em
            )
            values (
              'acesso_ml_liberado', 'aviso', 'acesso_liberado',
              format('O Mercado Livre voltou a responder 200 em %s. A fonte foi RELIGADA automaticamente e a coleta recomeca na proxima rodada. Conferir tambem /reviews/item/, que caiu junto em 23/11 e e usado por lerAvaliacao().', v_caminho),
              jsonb_build_object('caminho', v_caminho, 'bloqueado_desde', v_bloqueado),
              1, now(), now()
            )
            on conflict (chave_idempotencia) do update
              set ocorrencias = public.erros.ocorrencias + 1,
                  visto_ultimo_em = now(),
                  resolvido_em = null;
          end if;
        else
          v_mudou := 'segue_ok';
        end if;
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
    'transicao', v_mudou,
    'fonte_religada', v_religada
  );
end;
$function$;

revoke all on function public.sondar_acesso_ml() from public, anon, authenticated;
grant execute on function public.sondar_acesso_ml() to service_role;
