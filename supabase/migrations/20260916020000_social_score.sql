-- Social Score: qual oferta ja publicada merece Instagram, e em que formato
--
-- O CORTE JA ACONTECEU. Esta nota nao decide se a oferta e boa — isso o motor
-- ja respondeu, e so chega aqui o que passou e foi publicado no canal. Aqui a
-- pergunta e outra: entre coisas que ja valem a pena, qual delas rende um post
-- que faz alguem parar de rolar a tela.
--
-- Sao perguntas diferentes e a diferenca importa. "Isto e um bom negocio" nao
-- e a mesma coisa que "isto vira uma boa imagem". Desconto de 40% num produto
-- de R$ 50 e um bom negocio e um post fraco: economiza R$ 20. Desconto de 15%
-- num de R$ 2.000 tem numero pior e post melhor: economiza R$ 300.
--
-- POR QUE A COMISSAO NAO ENTRA AQUI
--
-- Ela ordena a leitura e a fila, e e onde este projeto decidiu que dinheiro
-- manda. Na escolha do que vai para o Instagram ela ficaria perigosamente
-- perto do corte: bastaria uma oferta pior render mais para ela ganhar a vez,
-- e o seguidor sentiria isso antes de saber explicar. O criterio segue sendo o
-- mesmo do canal — o que e bom para quem le.
--
-- O DENOMINADOR E O QUE DEU PARA OBSERVAR
--
-- Mesmo padrao de `pontuar()` em oferta.ts: cada componente tem peso, e o
-- denominador e a soma dos pesos DISPONIVEIS. Sinal ausente sai da conta em
-- vez de valer zero. Peso fixo com zero para o que falta e veneno — foi assim
-- que o Radar Rota passou 34 dias vivo publicando nada.
--
-- E existe um piso de cobertura, pelo mesmo motivo que `pontuar()` tem o dele.
-- Sem o piso, uma oferta da qual quase nada se sabe tira nota ALTA: sobram dois
-- componentes, os dois por acaso cheios, e a media deles da 100. Foi o que
-- aconteceu no primeiro teste — produto sem preco de referencia marcou 100 com
-- 23% de cobertura e foi parar no topo da lista. Nota confiante feita de nada e
-- pior do que nota baixa.
--
-- O QUE A NOTA AINDA NAO ENXERGA
--
-- Desempenho: nao existe nenhum dado de clique ou alcance no banco, entao ela e
-- cega para o que funcionou antes. Nao ha componente `desempenho` aqui de
-- proposito — componente que nunca fica disponivel so encolheria a cobertura de
-- todo mundo para sempre, e o piso viraria inalcancavel. Quando o rastreio por
-- SubID existir, ele entra como componente novo e os pesos sao rebalanceados
-- junto.
--
-- NAO EXISTE FAIXA DE REEL
--
-- Reel nao tem sticker de link — so bio. Colocar Reel no topo da escada, como
-- premio da nota mais alta, mandaria as melhores ofertas justamente para o
-- formato de menor conversao direta. Reel serve para alcance, e alcance nao se
-- decide por desconto.

-- ---------------------------------------------------------------------------
-- Prende um numero entre dois limites
-- ---------------------------------------------------------------------------

create or replace function public.entre(p_valor numeric, p_min numeric, p_max numeric)
returns numeric
language sql
immutable
set search_path to ''
as $$ select greatest(p_min, least(p_max, coalesce(p_valor, p_min))) $$;

comment on function public.entre(numeric, numeric, numeric) is
  'Prende um valor na faixa. Existe para as fracoes de 0 a 1 do Social Score.';

-- ---------------------------------------------------------------------------
-- Da nota para a decisao
--
-- Os cortes sao arbitrarios e vao mudar quando houver dado de clique. Ficam
-- numa funcao so para mudarem num lugar so.
-- ---------------------------------------------------------------------------

create or replace function public.faixa_social(p_nota integer)
returns text
language sql
immutable
set search_path to ''
as $$
  select case
    when coalesce(p_nota, 0) >= 75 then 'story_e_feed'
    when coalesce(p_nota, 0) >= 45 then 'story'
    else 'so_o_canal'
  end;
$$;

comment on function public.faixa_social(integer) is
  'Onde a oferta merece aparecer. Story antes de feed porque no story o link clica.';

-- ---------------------------------------------------------------------------
-- A nota
-- ---------------------------------------------------------------------------

create or replace function public.social_score(p_oferta_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_of record;
  v_economia numeric;
  v_repeticoes integer;
  v_componentes jsonb;
  v_peso_disponivel numeric;
  v_peso_total numeric;
  v_ganho numeric;
  v_nota integer;
  v_detalhe jsonb;
  v_ausentes jsonb;
begin
  select o.preco_atual, o.preco_original, o.desconto_percentual, o.pontuacao,
         o.id_externo, o.fonte_id, o.disponivel
  into v_of
  from public.ofertas o
  where o.id = p_oferta_id;

  if not found then
    return jsonb_build_object(
      'nota', 0, 'faixa', 'so_o_canal', 'motivo', 'oferta_inexistente'
    );
  end if;

  -- Economia em reais. Sem preco "de" observado nao ha o que subtrair, e o
  -- componente sai da conta em vez de virar zero — zero afirmaria que nao
  -- houve economia, e o que houve foi falta de referencia.
  v_economia := case
    when v_of.preco_original is not null and v_of.preco_original > v_of.preco_atual
      then v_of.preco_original - v_of.preco_atual
    else null
  end;

  -- Quantas vezes este mesmo produto ja foi ao canal no ultimo mes. Repetir o
  -- mesmo produto cansa quem segue mais rapido do que cansa quem le canal: no
  -- Telegram a pessoa rola e ignora, no feed ela deixa de seguir.
  --
  -- Conta por `oferta_id` e nao por `(fonte_id, id_externo)` porque
  -- `ofertas_fonte_externo_uk` ja garante que os dois sao a mesma coisa — um
  -- produto de uma fonte e uma linha so, republicada quantas vezes for. O join
  -- daria a mesma resposta pagando mais caro por ela.
  -- Sem economia em reais E sem desconto, nao ha numero para por na arte. O
  -- post seria uma foto de produto com preco — isso nao e promocao, e catalogo.
  -- Mesma ideia da porta de `pontuar()`: sem vantagem de preco nao existe
  -- oferta, existe so um produto.
  if v_economia is null and v_of.desconto_percentual is null then
    return jsonb_build_object(
      'nota', 0,
      'faixa', 'so_o_canal',
      'motivo', 'sem_numero_para_mostrar',
      'repeticoes_30d', 0
    );
  end if;

  select count(*)
  into v_repeticoes
  from public.publicacoes p
  where p.oferta_id = p_oferta_id
    and p.publicado_em > now() - interval '30 days';

  v_componentes := jsonb_build_array(
    -- O numero que faz parar de rolar a tela. R$ 300 de economia satura: dali
    -- para cima ja e "muito dinheiro" e o excedente nao impressiona mais.
    jsonb_build_object(
      'nome', 'economia',
      'peso', 30,
      'fracao', public.entre(coalesce(v_economia, 0) / 300.0, 0, 1),
      'disponivel', v_economia is not null
    ),

    -- A porcentagem e o que vai grande na arte. Piso em 15 porque e o corte do
    -- proprio motor; 60% satura.
    jsonb_build_object(
      'nome', 'desconto',
      'peso', 22,
      'fracao', public.entre((coalesce(v_of.desconto_percentual, 0) - 15) / 45.0, 0, 1),
      'disponivel', v_of.desconto_percentual is not null
    ),

    -- Faixa de compra por impulso. Abaixo de R$ 40 a economia nao muda a vida
    -- de ninguem; acima de R$ 1.500 ninguem compra vendo um story. O meio da
    -- faixa vale 1 e as pontas caem.
    jsonb_build_object(
      'nome', 'faixa_de_preco',
      'peso', 16,
      'fracao', case
        when v_of.preco_atual < 40 then public.entre(v_of.preco_atual / 40.0, 0, 1) * 0.5
        when v_of.preco_atual <= 600 then 1.0
        when v_of.preco_atual <= 1500 then public.entre((1500 - v_of.preco_atual) / 900.0, 0, 1)
        else 0.15
      end,
      'disponivel', true
    ),

    -- O veredito que o motor ja deu. Nao e recalculado aqui: seria uma segunda
    -- opiniao sobre uma pergunta que ja foi respondida.
    jsonb_build_object(
      'nome', 'qualidade',
      'peso', 20,
      'fracao', public.entre(coalesce(v_of.pontuacao, 0) / 100.0, 0, 1),
      'disponivel', v_of.pontuacao is not null
    ),

    -- Primeira vez vale inteiro; a segunda vale metade; da terceira em diante
    -- e repeteco.
    jsonb_build_object(
      'nome', 'ineditismo',
      'peso', 12,
      'fracao', case
        when v_repeticoes <= 1 then 1.0
        when v_repeticoes = 2 then 0.5
        else 0.0
      end,
      'disponivel', true
    )
  );

  select
    coalesce(sum((c->>'peso')::numeric) filter (where (c->>'disponivel')::boolean), 0),
    sum((c->>'peso')::numeric),
    coalesce(sum((c->>'peso')::numeric * (c->>'fracao')::numeric)
             filter (where (c->>'disponivel')::boolean), 0)
  into v_peso_disponivel, v_peso_total, v_ganho
  from jsonb_array_elements(v_componentes) c;

  select jsonb_object_agg(c->>'nome', round((c->>'peso')::numeric * (c->>'fracao')::numeric))
         filter (where (c->>'disponivel')::boolean),
         coalesce(jsonb_agg(c->>'nome') filter (where not (c->>'disponivel')::boolean), '[]'::jsonb)
  into v_detalhe, v_ausentes
  from jsonb_array_elements(v_componentes) c;

  -- Mesmo piso de `pontuar()`. Abaixo dele a nota seria uma opiniao forte sobre
  -- uma amostra pequena — e como ela ordena a fila do Instagram, uma opiniao
  -- forte feita de nada iria direto para o topo.
  if v_peso_disponivel / v_peso_total < 0.70 then
    return jsonb_build_object(
      'nota', 0,
      'faixa', 'so_o_canal',
      'motivo', 'cobertura_insuficiente',
      'cobertura', round(v_peso_disponivel / v_peso_total, 2),
      'ausentes', v_ausentes,
      'repeticoes_30d', v_repeticoes
    );
  end if;

  v_nota := round((v_ganho / v_peso_disponivel) * 100);

  return jsonb_build_object(
    'nota', v_nota,
    'faixa', public.faixa_social(v_nota),
    'cobertura', round(v_peso_disponivel / v_peso_total, 2),
    'componentes', coalesce(v_detalhe, '{}'::jsonb),
    'ausentes', v_ausentes,
    'economia', v_economia,
    'repeticoes_30d', v_repeticoes
  );
end;
$$;

comment on function public.social_score(bigint) is
  'Quanto esta oferta JA PUBLICADA rende como post. Decide distribuicao, nunca qualidade — o corte ja aconteceu no motor.';

-- ---------------------------------------------------------------------------
-- O texto do story, num lugar so
--
-- `para_story` ja montava este texto inline. Agora `para_o_instagram` precisa
-- do mesmo texto, e duas copias divergiriam — bastaria alguem corrigir a linha
-- de PUBLICIDADE em uma delas.
-- ---------------------------------------------------------------------------

create or replace function public.texto_do_story(
  p_titulo text,
  p_preco_atual numeric,
  p_preco_original numeric,
  p_desconto numeric
)
returns text
language sql
immutable
set search_path to ''
as $$
  select E'\U0001F525 ' || p_titulo || E'\n\n' ||
    case when p_preco_original is not null and p_preco_original > p_preco_atual
         then 'De R$ ' || public.dinheiro(p_preco_original) || E'\n'
         else '' end ||
    'R$ ' || public.dinheiro(p_preco_atual) ||
    case when p_desconto is not null
         then ' (-' || to_char(p_desconto, 'FM990') || '%)'
         else '' end || E'\n\n' ||
    E'Toca no link \U0001F446\n\n' ||
    'PUBLICIDADE • LINK DE AFILIADO';
$$;

comment on function public.texto_do_story(text, numeric, numeric, numeric) is
  'O texto que vai por cima da foto do story. Sem URL: no story quem clica e o sticker, e URL escrita so parece link quebrado.';

-- ---------------------------------------------------------------------------
-- A lista: o que ja foi publicado, com nota e destino
-- ---------------------------------------------------------------------------

create or replace function public.para_o_instagram(p_horas integer default 24)
returns table (
  nota integer,
  faixa text,
  produto text,
  foto text,
  chamada text,
  link_do_sticker text,
  economia numeric,
  por_que jsonb,
  publicado_em timestamptz
)
language sql
stable
security definer
set search_path to ''
as $$
  with recentes as (
    select p.publicado_em,
           o.id as oferta_id,
           o.preco_atual,
           o.preco_original,
           o.desconto_percentual,
           o.url_imagem,
           coalesce(o.url_afiliado, i.url_afiliado) as url_afiliado,
           case when char_length(o.titulo) > 55
                then left(o.titulo, 52) || '...'
                else o.titulo end as titulo_curto
    from public.publicacoes p
    join public.ofertas o on o.id = p.oferta_id
    join public.fontes f on f.id = o.fonte_id
    left join public.itens_ml i
      on i.plataforma = f.plataforma
     and coalesce(i.produto_catalogo, i.item_id) = o.id_externo
    where p.publicado_em > now() - make_interval(hours => greatest(1, coalesce(p_horas, 24)))
      and p.situacao = 'publicada'
      and o.disponivel
      and coalesce(o.url_afiliado, i.url_afiliado) is not null
  ),
  pontuadas as (
    select r.*, public.social_score(r.oferta_id) as s
    from recentes r
  )
  select (p.s->>'nota')::integer,
         p.s->>'faixa',
         p.titulo_curto,
         p.url_imagem,
         public.texto_do_story(p.titulo_curto, p.preco_atual, p.preco_original, p.desconto_percentual),
         p.url_afiliado,
         (p.s->>'economia')::numeric,
         p.s,
         p.publicado_em
  from pontuadas p
  -- Ordem da nota, e nao da hora: o objetivo e escolher, nao listar.
  order by (p.s->>'nota')::integer desc, p.publicado_em desc;
$$;

comment on function public.para_o_instagram(integer) is
  'Ofertas ja publicadas, ordenadas por quanto rendem como post, com o destino sugerido e o texto pronto.';

-- ---------------------------------------------------------------------------
-- `para_story` passa a usar o texto compartilhado
--
-- Mesmo retorno de antes; muda so de onde vem a `chamada`.
-- ---------------------------------------------------------------------------

create or replace function public.para_story(p_horas integer default 24)
returns table (
  publicado_em timestamptz,
  produto text,
  foto text,
  chamada text,
  link_do_sticker text,
  preco_no_post numeric,
  preco_agora numeric,
  o_preco text
)
language sql
stable
security definer
set search_path to ''
as $$
  with recentes as (
    select p.publicado_em,
           o.id as oferta_id,
           o.preco_atual,
           o.preco_original,
           o.desconto_percentual,
           o.url_imagem,
           o.disponivel,
           coalesce(o.url_afiliado, i.url_afiliado) as url_afiliado,
           case when char_length(o.titulo) > 55
                then left(o.titulo, 52) || '...'
                else o.titulo end as titulo_curto,
           (select h.preco
            from public.historico_precos h
            where h.oferta_id = o.id
              and h.observado_em <= p.publicado_em
            order by h.observado_em desc
            limit 1) as preco_publicado
    from public.publicacoes p
    join public.ofertas o on o.id = p.oferta_id
    join public.fontes f on f.id = o.fonte_id
    left join public.itens_ml i
      on i.plataforma = f.plataforma
     and coalesce(i.produto_catalogo, i.item_id) = o.id_externo
    where p.publicado_em > now() - make_interval(hours => greatest(1, coalesce(p_horas, 24)))
      and p.situacao = 'publicada'
      and coalesce(o.url_afiliado, i.url_afiliado) is not null
  ),
  ainda_de_pe as (
    select r.*, coalesce(r.preco_publicado, r.preco_atual) as referencia
    from recentes r
    where r.disponivel
  )
  select
    a.publicado_em,
    a.titulo_curto,
    a.url_imagem,
    public.texto_do_story(a.titulo_curto, a.preco_atual, a.preco_original, a.desconto_percentual),
    a.url_afiliado,
    a.referencia,
    a.preco_atual,
    case
      when a.preco_atual > a.referencia then 'SUBIU desde o post — confira antes'
      when a.preco_atual < a.referencia then 'caiu mais ainda'
      else 'mesmo preço do post'
    end
  from ainda_de_pe a
  order by (a.preco_atual - a.referencia) asc, a.publicado_em desc;
$$;

-- ---------------------------------------------------------------------------
-- Permissoes
-- ---------------------------------------------------------------------------

revoke all on function public.entre(numeric, numeric, numeric) from public, anon;
revoke all on function public.social_score(bigint) from public, anon;
revoke all on function public.faixa_social(integer) from public, anon;
revoke all on function public.texto_do_story(text, numeric, numeric, numeric) from public, anon;
revoke all on function public.para_o_instagram(integer) from public, anon;

grant execute on function public.entre(numeric, numeric, numeric) to service_role, authenticated;
grant execute on function public.social_score(bigint) to service_role, authenticated;
grant execute on function public.faixa_social(integer) to service_role, authenticated;
grant execute on function public.texto_do_story(text, numeric, numeric, numeric) to service_role, authenticated;
grant execute on function public.para_o_instagram(integer) to service_role, authenticated;
