-- O boletim 2x/dia gastava de 4 a 6 consultas separadas, e cada consulta e um
-- pedido de autorizacao numa sessao na nuvem. Isso cobrou caro de verdade: em
-- 05 e 06/10 varias consultas do boletim morreram com o pedido pendurado
-- quando um check-in do vigia chegou em cima, e o boletim da noite nao saiu.
--
-- Nao da para eu reduzir os pedidos pelo lado do arquivo de permissao (um
-- agente nao escreve a propria permissao, e tentar foi bloqueado tres vezes,
-- com razao). Da para reduzir pelo lado do BANCO: se o relatorio inteiro cabe
-- em uma funcao, o boletim passa a ser UMA chamada em vez de seis.
--
-- Isso tambem segue a doutrina do projeto: regra que mora no texto de quem
-- pergunta pode errar diferente em cada lugar. `fila_pendente()` nasceu disso.
-- Aqui a MONTAGEM do relatorio tambem passa a morar no banco, uma vez.

create or replace function public.boletim(p_horas int default 13)
returns jsonb language sql stable security definer set search_path to ''
as $function$
  select jsonb_build_object(

    -- 1) O QUE FOI AO AR. Le snapshot_payload, nunca preco_atual: a oferta
    -- segue mudando depois de publicada, e reportar o campo vivo faz o
    -- boletim mentir sobre o que o canal viu (erro cometido em 01/10 com uma
    -- Smart TV). O snapshot e o unico registro honesto.
    'publicou', coalesce((
      select jsonb_agg(jsonb_build_object(
               'quando', to_char(p.publicado_em - interval '3 hours', 'DD/MM HH24:MI'),
               'fonte',  f.slug,
               'texto',  p.snapshot_payload->>'text')
             order by p.publicado_em desc)
        from public.publicacoes p
        join public.ofertas o on o.id = p.oferta_id
        join public.fontes  f on f.id = o.fonte_id
       where p.publicado_em > now() - make_interval(hours => p_horas)
    ), '[]'::jsonb),

    'publicou_24h', (
      select count(*) from public.publicacoes
       where publicado_em > now() - interval '24 hours'),

    -- 2) SAUDE. Por fonte, porque o veredito global fica 'saudavel' com uma
    -- fonte muda se a outra publica.
    'saude_por_fonte', public.saude_da_coleta()->'por_fonte',
    'link',            public.integridade_do_link(48),
    'token', (
      select jsonb_build_object('situacao', situacao, 'geracao', geracao,
                                'erro', ultimo_erro_codigo)
        from public.credenciais_ml),

    -- Pela funcao, nunca contando a tabela a mao. Ver fila_pendente().
    'fila_pendente', public.fila_pendente(),

    -- Os dois alarmes que medem ENTREGA, nao leitura. Vazio = nada a dizer.
    'alarme_entrega',  public.entrega_por_fonte(),
    'ofertas_perdidas', public.aprovacoes_vencidas(24),

    -- 3) O FUNIL DE LINKS. A secao mais importante para o dono: cada linha e
    -- um produto que JA PROVOU vantagem de preco e nao pode publicar porque
    -- falta o link de afiliado, que so sai do painel do ML na mao.
    'funil', coalesce((
      select jsonb_agg(to_jsonb(x) order by (x.desconto) desc)
        from public.ml_prontos_para_link() x
    ), '[]'::jsonb),

    'cota_descoberta', (
      select jsonb_build_object(
               'teto', public.watchlist_teto_sem_link(),
               'ocupada', count(*) filter (where habilitado and url_afiliado is null),
               'mais_antigo_sem_link', min(criado_em) filter (
                  where habilitado and url_afiliado is null)::date)
        from public.itens_ml),

    -- 4) SHOPEE. Zero aprovados NAO se reporta como "nada passou": a rodada
    -- grava a nota maxima e os componentes de quem chegou mais perto.
    'shopee', coalesce((
      select jsonb_agg(jsonb_build_object(
               'inicio', to_char(z.iniciada_em - interval '3 hours', 'DD/MM HH24:MI'),
               'vistos', z.itens_vistos,
               'aprovados', z.itens_enfileirados,
               'corte', z.metadados->'corte_em_uso',
               'nota_maxima', z.metadados->'pontuacao_maxima',
               'componentes_do_melhor', z.metadados->'quase_aprovou'->'componentes',
               'recusas', z.metadados->'recusas_por_nota',
               'erro', z.resumo_erro)
             order by z.iniciada_em desc)
        from (select * from public.execucoes
               where identificador_worker like 'coletor-shopee%'
               order by iniciada_em desc limit 3) z
    ), '[]'::jsonb),

    'gerado_em', to_char(now() - interval '3 hours', 'DD/MM/YYYY HH24:MI')
  )
$function$;

comment on function public.boletim(int) is
  'O relatorio 2x/dia inteiro numa chamada. Existe para o boletim custar UM '
  'pedido de autorizacao em vez de seis: consulta pendurada que um check-in '
  'fecha em cima ja custou dois boletins (05-06/10). Le snapshot_payload, '
  'nunca preco_atual.';

revoke all on function public.boletim(int) from public, anon;
grant execute on function public.boletim(int) to authenticated, service_role;
