-- O veredito passa a enxergar coletor que roda e nao le
--
-- Em 15/09 o Baixou estava ha 62 horas sem ler um unico preco, e
-- saude_da_coleta() respondia veredito 'saudavel'. Nao era bug de calculo: o
-- veredito so mede se a RODADA acontece, e elas aconteciam — 30 por hora, todas
-- saindo como 'ignorada' porque a credencial do Mercado Livre tinha morrido.
--
-- O README ja dizia o que fazer, na propria voz do projeto:
--
--   "Ela cruza rodada com leitura de preco de proposito: coletor que roda e nao
--    le e uma falha diferente de coletor que nao roda, e as duas precisam
--    aparecer."
--
-- As duas apareciam em campos separados — minutos_desde_a_leitura marcava 3754
-- e revisita_veredito dizia 'sem_leitura'. Mas quem le a saude olha o veredito
-- primeiro, e ele dizia que estava tudo bem. Campo secundario correto nao salva
-- um veredito principal que mente.
--
-- Entao entra o estado 'cega': a rodada anda, a leitura nao. E vem acompanhado
-- do motivo, lido dos metadados da ultima rodada — quando o coletor desiste ele
-- registra por que ('reautorizacao_necessaria', 'travada', etc.), e essa e
-- exatamente a informacao que faltava para o alarme dizer o que fazer em vez de
-- so dizer que algo esta errado.
--
-- Os 20 minutos sao os mesmos de 'muda'. Com rodada a cada 2 minutos lendo 10
-- itens, 20 minutos sem leitura nenhuma nao e variacao: e parada.
--
-- Ordem dos testes: primeiro se o motor gira, depois se ele enxerga. Coletor
-- parado ja e relatado por 'muda'; nao faz sentido chama-lo de cego tambem.

create or replace function public.saude_da_coleta()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_ultima_rodada timestamptz;
  v_ultima_leitura timestamptz;
  v_minutos numeric;
  v_minutos_leitura numeric;
  v_veredito text;
  v_watchlist integer;
  v_leituras integer;
  v_revisita numeric;
  v_motivo text;
begin
  select max(e.iniciada_em) into v_ultima_rodada
  from public.execucoes e where e.tipo = 'coleta';

  select max(h.observado_em) into v_ultima_leitura from public.historico_precos h;

  v_minutos := extract(epoch from (now() - v_ultima_rodada)) / 60.0;
  v_minutos_leitura := extract(epoch from (now() - v_ultima_leitura)) / 60.0;

  -- Por que a ultima rodada desistiu. O coletor grava isso ao sair sem ler;
  -- e o que transforma "algo esta errado" em "reconecte o Mercado Livre".
  select e.metadados ->> 'motivo' into v_motivo
  from public.execucoes e
  where e.tipo = 'coleta'
  order by e.iniciada_em desc
  limit 1;

  v_veredito := case
    when v_ultima_rodada is null then 'sem_registro'
    when v_minutos > 20 then 'muda'
    when v_minutos > 10 then 'atrasada'
    -- A rodada anda, a leitura nao. Falha propria, nao variacao.
    when v_ultima_leitura is null or v_minutos_leitura > 20 then 'cega'
    else 'saudavel'
  end;

  select count(*) into v_watchlist from public.itens_ml where habilitado;

  select count(*) into v_leituras from public.historico_precos
  where observado_em > now() - interval '1 hour';

  -- Sem leitura na ultima hora nao da para estimar revisita. Devolve null em
  -- vez de dividir por zero ou fingir um numero: quem le precisa distinguir
  -- "esticada" de "nao sei".
  v_revisita := case when v_leituras > 0
                     then round(v_watchlist::numeric / v_leituras, 2)
                     end;

  return jsonb_build_object(
    'veredito', v_veredito,
    -- Preenchido quando o veredito e 'cega': o que a ultima rodada alegou ao
    -- desistir. Null quando ela leu normalmente.
    'motivo_da_cegueira', case when v_veredito = 'cega' then v_motivo end,
    'ultima_rodada_em', v_ultima_rodada,
    'minutos_desde_a_rodada', round(v_minutos, 1),
    'ultima_leitura_em', v_ultima_leitura,
    'minutos_desde_a_leitura', round(v_minutos_leitura, 1),
    'rodadas_1h', (
      select count(*) from public.execucoes
      where tipo = 'coleta' and iniciada_em > now() - interval '1 hour'
    ),
    'falhas_1h', (
      select count(*) from public.execucoes
      where tipo = 'coleta' and situacao in ('falhou', 'parcial')
        and iniciada_em > now() - interval '1 hour'
    ),
    'penduradas', (
      select count(*) from public.execucoes
      where situacao = 'rodando' and iniciada_em < now() - interval '15 minutes'
    ),
    'leituras_1h', v_leituras,
    'itens_na_watchlist', v_watchlist,
    -- Quantos nao podem virar comissao. Se este numero cresce, a descoberta
    -- esta correndo mais rapido do que os links sao gerados.
    'itens_sem_link', (
      select count(*) from public.itens_ml where habilitado and url_afiliado is null
    ),
    -- Horas entre duas leituras do mesmo item.
    'revisita_horas', v_revisita,
    'revisita_veredito', case
      when v_revisita is null then 'sem_leitura'
      when v_revisita > 2 then 'esticada'
      else 'ok'
    end
  );
end;
$$;

comment on function public.saude_da_coleta() is
  'Saude da coleta. O veredito separa motor parado (muda/atrasada) de motor que gira sem enxergar (cega), porque sao falhas diferentes.';

revoke all on function public.saude_da_coleta() from public, anon;
grant execute on function public.saude_da_coleta() to service_role, authenticated;
