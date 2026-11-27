-- Reconectar o Mercado Livre volta a destravar a coleta
--
-- Em 15/09 a credencial do ML foi reconectada pelo fluxo OAuth. Os tokens
-- entraram no cofre, expira_em e conectado_em foram atualizados, o ML devolveu
-- refresh_token novo — e a coleta continuou parada.
--
-- oauth_ml_gravar_tokens gravava os tokens e os carimbos de tempo, mas nao
-- tocava na maquina de estado: situacao seguia 'reautorizacao_necessaria' e
-- ultimo_erro_codigo seguia 'renovacao_recusada', do incidente de 12/09.
--
-- E ml_token_adquirir faz curto-circuito logo no comeco:
--
--   if v.situacao = 'reautorizacao_necessaria' then
--     precisa_renovar := false; return;
--
-- Ou seja, o coletor desistia antes de olhar o token — que estava ali, valido,
-- recem-gravado. Toda rodada saia 'ignorada'. Reconectar nao podia funcionar:
-- o unico caminho documentado para sair de 'reautorizacao_necessaria' era o
-- fluxo OAuth, e o fluxo OAuth nao limpava esse estado. Beco sem saida.
--
-- Custou 62 horas de cegueira que nao precisavam ter acontecido: a credencial
-- morreu em 12/09 as 10:00, e a reconexao de 15/09 as 01:03 teria resolvido na
-- hora se a gravacao tivesse feito o reset.
--
-- Agora uma conexao nova declara o que ela e: credencial valida, sem erro
-- pendente, sem retentativa agendada, e geracao nova para invalidar qualquer
-- renovacao em voo que ainda carregue a geracao velha.
--
-- O lease tambem e solto. As quatro colunas de lock andam juntas por
-- constraint, entao vao todas a null de uma vez: um lease preso de antes da
-- reconexao nao tem por que sobreviver a ela.
--
-- O reset so acontece em p_primeira_conexao, que a Edge Function passa como
-- true apenas no retorno do OAuth — renovacao de rotina segue por
-- ml_token_renovado, que tem a propria maquina de estado e nao e mexida aqui.

create or replace function public.oauth_ml_gravar_tokens(
  p_access_token text,
  p_refresh_token text,
  p_expires_in integer,
  p_usuario_id text default null,
  p_escopos text default null,
  p_primeira_conexao boolean default false
)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if p_expires_in is null or p_expires_in < 300 then
    raise exception 'expires_in implausivel: %', p_expires_in using errcode = '22023';
  end if;

  perform public.cofre_gravar('baixou_ml_access_token', p_access_token);
  perform public.cofre_gravar('baixou_ml_refresh_token', p_refresh_token);

  update public.credenciais_ml
    set usuario_id = coalesce(p_usuario_id, usuario_id),
        escopos = coalesce(p_escopos, escopos),
        expira_em = now() + make_interval(secs => p_expires_in),
        renovado_em = now(),
        conectado_em = case
          when p_primeira_conexao then now()
          else coalesce(conectado_em, now())
        end,

        -- Conexao nova e credencial valida. Sem isto, situacao ficava presa em
        -- 'reautorizacao_necessaria' e ml_token_adquirir nunca chegava a usar o
        -- token recem-gravado.
        situacao = case when p_primeira_conexao then 'pronta' else situacao end,
        ultimo_erro_codigo = case when p_primeira_conexao then null else ultimo_erro_codigo end,
        tentar_apos = case when p_primeira_conexao then null else tentar_apos end,

        -- Invalida renovacao em voo que carregue a geracao velha.
        geracao = case when p_primeira_conexao then geracao + 1 else geracao end,

        -- Lease de antes da reconexao nao sobrevive a ela. As quatro colunas
        -- andam juntas por constraint.
        locada_por = case when p_primeira_conexao then null else locada_por end,
        lock_token = case when p_primeira_conexao then null else lock_token end,
        locada_em = case when p_primeira_conexao then null else locada_em end,
        lock_expira_em = case when p_primeira_conexao then null else lock_expira_em end
    where id = 1;
end;
$$;

comment on function public.oauth_ml_gravar_tokens(text, text, integer, text, text, boolean) is
  'Grava os tokens do ML. Em primeira conexao tambem reseta a maquina de estado: sem isso, reconectar nao tira a credencial de reautorizacao_necessaria.';
