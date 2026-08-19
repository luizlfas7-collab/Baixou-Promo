-- As quatro fontes nascem aqui, e nao inseridas a mao em producao: um banco
-- novo aplicando so as migrations precisa ficar identico ao que roda.
-- Todas nascem desabilitadas; ligar e decisao de operacao.
insert into public.fontes (slug, nome, plataforma, tipo_fonte, url_base, nome_segredo, configuracao, habilitada, intervalo_coleta_segundos)
values
  (
    'mercado_livre_api_oficial',
    'Mercado Livre — API oficial',
    'mercado_livre',
    'api_oficial',
    'https://api.mercadolibre.com',
    'mercado_livre_oauth',
    jsonb_build_object(
      'itens_por_rodada', 5,
      'reputacao_minima_vendedor', jsonb_build_array('4_light_green', '5_green'),
      'nota_minima', 4.5,
      'avaliacoes_minimas', 20,
      'exige_produto_novo', true,
      'divergencia_maxima_desconto_pp', 2
    ),
    false,
    300
  ),
  (
    'shopee_open_api',
    'Shopee — Open API de afiliados',
    'shopee',
    'api_oficial',
    'https://open-api.affiliate.shopee.com.br',
    'shopee_afiliados',
    jsonb_build_object(
      'palavras_chave', jsonb_build_array('fone de ouvido', 'smartwatch', 'teclado mecanico', 'cadeira gamer', 'ssd', 'power bank'),
      'limite_por_palavra', 10,
      'nota_minima', 4.7,
      'vendas_minimas', 100,
      'comissao_minima', 0.05,
      'preco_minimo', 30
    ),
    false,
    900
  ),
  (
    'kabum_web',
    'KaBuM! — catálogo oficial',
    'kabum',
    'feed_parceiro',
    'https://www.kabum.com.br',
    null,
    jsonb_build_object(
      'modo', 'somente_observacao',
      'caminhos_categoria', jsonb_build_array(
        '/computadores/computador-gamer',
        '/hardware/placa-de-video',
        '/hardware/memoria-ram',
        '/hardware/ssd-2-5',
        '/perifericos/teclado',
        '/perifericos/mouse'
      ),
      'preco_minimo', 100,
      'desconto_minimo_percentual', 10,
      'nota_minima', 4.5,
      'avaliacoes_minimas', 10,
      'limite_por_rodada', 120
    ),
    false,
    1800
  ),
  (
    'amazon_associados',
    'Amazon — Associados',
    'amazon',
    'portal_afiliado',
    'https://www.amazon.com.br',
    'amazon_associados',
    jsonb_build_object(
      'modo', 'somente_observacao',
      'nota_minima', 4.3,
      'avaliacoes_minimas', 30,
      'desconto_minimo_percentual', 10,
      'limite_por_rodada', 60,
      'observacao', 'Sem coletor ainda: depende de conta aprovada na Amazon Associados.'
    ),
    false,
    1800
  ),
  (
    'cupons_de_loja',
    'Cupons de loja — cadastro manual',
    'manual',
    'importacao_manual',
    null,
    null,
    jsonb_build_object(
      'max_cupons_por_dia', 4,
      'max_cupons_por_loja_por_dia', 2,
      'intervalo_minimo_entre_cupons_segundos', 900,
      'folga_apos_qualquer_post_segundos', 120,
      'descanso_para_repetir_horas', 24,
      'antecedencia_minima_do_vencimento_segundos', 3600,
      'prioridade_na_fila', 200
    ),
    false,
    300
  );
