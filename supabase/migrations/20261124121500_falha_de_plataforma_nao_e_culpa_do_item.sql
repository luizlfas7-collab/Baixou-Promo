-- EMERGENCIA MEDIDA EM 24/11 11:45 UTC. A watchlist do ML estava a UMA rodada
-- de ser zerada inteira, e ninguem tinha feito nada errado.
--
-- O QUE ACONTECEU. Em 23/11 17:22 o Mercado Livre passou a responder 403
-- PA_UNAUTHORIZED_RESULT_FROM_POLICIES (blocked_by: PolicyAgent) em
-- /products/{catalogo}/items, que e o unico endpoint desta aplicacao que
-- devolve PRECO. Medido com ensaio_get_ml em 24/11:
--   /products/{catalogo}        -> 200  (titulo, foto, status; buy_box_winner nulo)
--   /products/{catalogo}/items  -> 403  PolicyAgent
--   /sites/MLB/search?catalog_product_id=  -> 403 forbidden
--   /items/{id}                 -> 403  access_denied
-- O token esta valido: o 200 prova. E politica de acesso do ML, nao credencial.
--
-- O DANO COLATERAL, que e o que esta migracao conserta. O coletor chama
-- ml_item_falhou() para toda falha nao retentavel, e `acesso_negado` (401/403)
-- estava na lista das nao retentaveis. ml_item_falhou incrementa
-- falhas_seguidas e DESABILITA o item em 9. ml_item_observado zera o contador
-- a cada leitura boa — logo, com o ML lendo normalmente ate 17:22, todo
-- contador estava em zero.
--
-- As 11:45 de 24/11, 18 horas depois:
--   369 itens habilitados, e TODOS OS 369 com falhas_seguidas > 0
--   media 8,1 falhas   |   pior 9   |   corte de desabilitacao: 9
--   369 de 369 com 7 ou mais, ou seja, todos a um passo de cair
--   ultima proxima_observacao_em agendada: 24/11 15:38
-- Nao era risco teorico. Em poucas horas a watchlist do ML estaria vazia, e
-- quando o acesso voltasse nao haveria o que ler. Reconstruir 369 itens com
-- link de afiliado e trabalho manual do dono, item por item.
--
-- O PRINCIPIO QUE ESTAVA ESCRITO E NAO ESTAVA VALENDO. O proprio coletor diz,
-- sobre falha de rede: "Falha de rede nao e culpa do item: nao conta contra
-- ele." Vale igual para 403 de politica. O item nao fez nada; a porta fechou.
-- Punir o item por isso e transformar uma indisponibilidade temporaria da
-- fonte em perda permanente de cadastro — exatamente o tipo de mecanismo que
-- falha calado que este projeto existe para nao ter.
--
-- Falha de PLATAFORMA passa a nao contra o item: so grava o motivo e espera
-- 15 minutos. Falha DO ITEM (fora do catalogo, sem anuncio, sem preco,
-- inativo) continua contando e continua desabilitando em 9, porque ai o
-- cadastro realmente morreu e a watchlist deve se limpar.
--
-- O alarme NAO e silenciado: a rodada continua marcada `falhou`, o veredito
-- da fonte continua `cega` e o vigia continua avisando — como avisou as 17:43,
-- 21 minutos depois do inicio. O que muda e so a cobranca indevida ao item.
create or replace function public.ml_item_falhou(p_id bigint, p_motivo text)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_da_plataforma boolean;
begin
  -- Motivos que vem da FONTE, nao do item. Sao as mensagens que
  -- mercadolivre.ts monta para 401/403, limite de taxa e 5xx, mais os codigos
  -- que o proprio ML devolve no corpo.
  v_da_plataforma := p_motivo ~* '(HTTP 40[13])|acesso negado|PA_UNAUTHORIZED|PolicyAgent|access_denied|forbidden|limite de taxa|servidor do ml respondeu 5';

  if v_da_plataforma then
    update public.itens_ml
      set ultimo_erro = left(p_motivo, 500),
          proxima_observacao_em = now() + interval '15 minutes'
      where id = p_id;
    return;
  end if;

  update public.itens_ml
    set falhas_seguidas = falhas_seguidas + 1,
        ultimo_erro = left(p_motivo, 500),
        habilitado = case when falhas_seguidas + 1 >= 9 then false else habilitado end,
        proxima_observacao_em = now() + make_interval(
          secs => least(300 * power(2, least(falhas_seguidas, 6))::integer, 86400)
        )
    where id = p_id;
end;
$function$;

revoke all on function public.ml_item_falhou(bigint, text) from public, anon, authenticated;
grant execute on function public.ml_item_falhou(bigint, text) to service_role;

-- REPARO do que a cegueira ja cobrou. Zera o contador dos itens cujo ultimo
-- erro e o 403 de politica, e devolve os que cairam DURANTE a cegueira. O
-- recorte por data existe para nao ressuscitar os 662 itens desabilitados ao
-- longo de meses por motivo legitimo: so entra o que a janela desta falha
-- marcou. proxima_observacao_em volta para agora, e o coletor retoma 10 por
-- rodada no ritmo normal assim que o ML reabrir.
update public.itens_ml
   set falhas_seguidas = 0,
       habilitado = true,
       proxima_observacao_em = now()
 where ultimo_erro ~* '(HTTP 40[13])|PA_UNAUTHORIZED|PolicyAgent|acesso negado'
   and atualizado_em > '2026-11-23 17:00:00+00'::timestamptz;
