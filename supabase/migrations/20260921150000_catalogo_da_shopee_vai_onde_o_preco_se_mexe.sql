-- O catalogo da Shopee vai para onde o preco se mexe.
--
-- SINTOMA: cinco dias no ar, 96 rodadas por dia, zero disparos.
--
-- MEDIDO, e o numero que decide: das 74 ofertas julgadas numa rodada, as 74
-- foram barradas pelo MESMO motivo — `sem_vantagem_de_preco`, pontuacao 0.
-- Os filtros de nota, preco e ganho barram ~23 de 60 e nao sao o gargalo.
--
-- CAUSA, em 190 leituras por oferta:
--   ofertas com historico ................ 80
--   que mudaram de preco alguma vez ...... 14
--   que cairam >=10% ...................... 4
--   que cairam >=15% ...................... 2
--   melhor competitividade ............... 10   (piso para publicar: 13)
--
-- Quase toda oferta tem `abaixo_da_referencia_pct` igual a zero: o preco de
-- hoje E o preco de referencia. Ele nao se move.
--
-- As seis palavras atuais sao 100% gadget de tecnologia, categoria em que o
-- vendedor da Shopee crava o preco e deixa. Enquanto isso, o que o proprio
-- canal publicou no ML foi perfume (-27%), percarbonato (-30%), Galaxy A17
-- (-30%), escova progressiva, parafusadeira. Beleza, casa e ferramenta se
-- mexem; gadget barato nao.
--
-- E tem o tamanho da amostra: 6 palavras x 10 itens = 60 vistos, ~37 que
-- ficam. O ML tem 321 na watchlist. Mesmo que a Shopee fosse tao volatil
-- quanto o ML, 37 itens renderiam ~0,4 post por dia.
--
-- CORRECAO: ampliar o catalogo, nao afrouxar a regua.
--   - as 6 palavras atuais FICAM. Cinco dias de historico de preco sao o
--     ativo que torna a vantagem apuravel; jogar fora zeraria o relogio.
--   - +8 palavras em categorias que a nossa propria operacao ja provou
--     voláteis. Sete vem de publicacao real no ML (parafusadeira 4x,
--     smartphone 3x, camera de seguranca 2x, monitor gamer 2x, perfume,
--     escova progressiva, fritadeira eletrica); `secador de cabelo` e a
--     unica extrapolacao, vizinha de beleza da escova.
--   - limite_por_palavra de 10 para 15.
--   Resultado: 60 -> 210 itens vistos por rodada, 3,5x.
--
-- O QUE NAO MUDA, de proposito: o piso de competitividade 13. O melhor item
-- da Shopee hoje esta em 10, que e um desconto de 5,6%. Publicar isso ao lado
-- dos -30% do ML barateia o canal. O gargalo e a amostra, nao a regua.
--
-- CUSTO: a rodada vai de ~8,5s para ~30s estimados (o laco e sequencial por
-- palavra, uma chamada GraphQL cada). O cron da Shopee roda de 16 em 16
-- minutos, entao nao ha risco de sobreposicao. Uma palavra que falhar nao
-- derruba a rodada: o coletor conta a falha e segue para a proxima.
--
-- Nenhum deploy: `palavras_chave` e `limite_por_palavra` ja sao lidos da
-- configuracao, e o codigo ja aceita limite ate 50.

update public.fontes
set configuracao = configuracao || jsonb_build_object(
      'palavras_chave', jsonb_build_array(
        -- as seis originais, preservadas pelo historico que ja acumularam
        'fone de ouvido',
        'smartwatch',
        'teclado mecanico',
        'cadeira gamer',
        'ssd',
        'power bank',
        -- categorias com disparo comprovado no ML
        'parafusadeira',
        'smartphone',
        'camera de seguranca',
        'monitor gamer',
        'perfume',
        'escova progressiva',
        'fritadeira eletrica',
        -- unica extrapolacao: vizinha de beleza da escova progressiva
        'secador de cabelo'
      ),
      'limite_por_palavra', 15
    ),
    atualizado_em = now()
where slug = 'shopee_open_api';

do $$
declare
  v_cfg jsonb;
  v_palavras integer;
  v_limite integer;
begin
  select configuracao into v_cfg from public.fontes where slug = 'shopee_open_api';

  if v_cfg is null then
    raise exception 'A fonte shopee_open_api nao existe';
  end if;

  v_palavras := jsonb_array_length(v_cfg -> 'palavras_chave');
  v_limite := (v_cfg ->> 'limite_por_palavra')::integer;

  if v_palavras <> 14 then
    raise exception 'Esperava 14 palavras-chave, encontrei %', v_palavras;
  end if;

  if v_limite <> 15 then
    raise exception 'Esperava limite_por_palavra 15, encontrei %', v_limite;
  end if;

  -- As seis originais tem que continuar la: elas carregam o historico.
  if not (v_cfg -> 'palavras_chave' @> '["fone de ouvido","smartwatch","teclado mecanico","cadeira gamer","ssd","power bank"]'::jsonb) then
    raise exception 'Uma das seis palavras originais se perdeu na atualizacao';
  end if;

  -- Os filtros de qualidade seguem intocados.
  if (v_cfg ->> 'nota_minima')::numeric <> 4.7
     or (v_cfg ->> 'ganho_minimo')::numeric <> 1
     or (v_cfg ->> 'preco_minimo')::numeric <> 15
     or (v_cfg ->> 'vendas_minimas')::integer <> 100 then
    raise exception 'Os filtros de qualidade foram alterados sem intencao: %', v_cfg;
  end if;
end $$;
