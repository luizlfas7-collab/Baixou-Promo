-- ---------------------------------------------------------------------------
-- Os filtros da Shopee, corrigidos contra dado real.
--
-- A fonte shopee_open_api foi semeada em 20260816234048 com filtros escritos
-- antes de qualquer resposta da API existir. Com a chave no Vault deu para
-- amostrar 120 itens nas seis palavras-chave configuradas e conferir.
--
-- Dois numeros estavam errados, e um deles contradizia o proprio projeto.
--
-- 1. comissao_minima 0.05 -> vira ganho_minimo 1.00
--
--    A migracao 20260902000000 ja tinha escrito a regra: "produto de comissao
--    MENOR paga mais. O que ordena e preco x comissao, nunca a taxa isolada."
--    A fonte da Shopee nasceu violando isso, porque nasceu antes.
--
--    Na amostra de 120: o piso de 5% barra 29 itens de preco medio R$ 383 e
--    comissao de 3%, que pagariam R$ 11,49 cada; e aprova 5 itens de R$ 10,72
--    com 7%, que pagam R$ 0,75. Trocar taxa por ganho esperado inverte isso.
--
--    R$ 1,00 e o piso: abaixo disso o clique nao paga o espaco no canal. A
--    mediana da amostra ficou em R$ 2,75 e o p75 em R$ 8,97, entao o corte
--    limpa a cauda sem encostar no miolo.
--
-- 2. preco_minimo 30 -> 15
--
--    O piso de R$ 30 derruba 49 dos 120. Produto barato de giro alto e o que
--    a Shopee tem de melhor — na palavra "fone de ouvido" os cinco primeiros
--    resultados custam entre R$ 13 e R$ 25, com nota 4,7+ e milhares de vendas,
--    e o piso antigo eliminava todos. R$ 15 abre isso sem descer ao troco.
--
-- nota_minima e vendas_minimas ficam como estao: 98 dos 120 ja passam, o que
-- diz que sao piso de sanidade e nao de selecao. Quem seleciona e a vantagem
-- de preco apurada contra o proprio historico, como em qualquer fonte.
--
-- O Mercado Livre nao e tocado. Filtro mora em fontes.configuracao, uma linha
-- por fonte; esta migracao mexe so na linha da Shopee.
-- ---------------------------------------------------------------------------

update public.fontes
set configuracao = (configuracao - 'comissao_minima')
                   || jsonb_build_object('ganho_minimo', 1.00, 'preco_minimo', 15),
    atualizado_em = now()
where slug = 'shopee_open_api';

do $$
declare
  v_cfg jsonb;
begin
  select configuracao into v_cfg from public.fontes where slug = 'shopee_open_api';

  if v_cfg ? 'comissao_minima' then
    raise exception 'comissao_minima continua na configuracao da Shopee';
  end if;

  if (v_cfg ->> 'ganho_minimo')::numeric is distinct from 1.00 then
    raise exception 'ganho_minimo nao ficou em 1.00';
  end if;

  if (v_cfg ->> 'preco_minimo')::numeric is distinct from 15 then
    raise exception 'preco_minimo nao ficou em 15';
  end if;
end;
$$;
