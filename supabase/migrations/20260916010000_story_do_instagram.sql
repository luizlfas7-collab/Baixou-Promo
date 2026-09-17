-- Story do Instagram: a oferta ja publicada, vestida para onde o link clica
--
-- POR QUE STORY, E NAO FEED
--
-- Na legenda do feed o link nao clica. Por isso `para_compartilhar` manda o
-- leitor para a bio — o que custa um toque a mais e derruba quase todo o
-- clique. No story o link clica: o sticker de link deixou de ser privilegio de
-- conta grande em 2021 e hoje vale para qualquer perfil. Para um projeto que
-- vive de comissao, essa e a diferenca entre distribuir e so aparecer.
--
-- E tem um segundo motivo, menos obvio e igualmente forte: story expira em
-- 24 horas, e oferta tambem. Post de feed com preco de promocao fica no grid
-- para sempre — semanas depois alguem entra, ve "R$ 899", clica, encontra
-- R$ 1.299 e conclui que o perfil mente. O story se limpa sozinho, no mesmo
-- ritmo em que a oferta morre. O formato efemero nao e um defeito aqui, e o
-- encaixe.
--
-- POR QUE O LINK VEM SEPARADO DO TEXTO
--
-- A Graph API do Instagram publica story, mas NAO publica sticker — nem de
-- link, nem de enquete, nem de localizacao. Automatizar o envio produziria
-- story sem link clicavel, ou seja, exatamente o que nao gera comissao.
-- Entao o story sobe a mao, e o sticker e colado a mao.
--
-- Por isso `link_do_sticker` e uma coluna propria e a `chamada` nao contem
-- URL nenhuma. URL digitada dentro do story nao vira link: fica um texto que
-- o leitor tenta tocar, nao acontece nada, e o post inteiro passa a impressao
-- de robo mal feito. O link mora no sticker, e o texto so aponta para ele.
--
-- A linha de PUBLICIDADE vai aqui como vai em todo formato. Exigencia legal
-- nao muda de plataforma.

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
           -- Titulo de story aguenta menos que o do WhatsApp: ele divide a
           -- tela com a foto, e texto comprido vira parede.
           case when char_length(o.titulo) > 55
                then left(o.titulo, 52) || '...'
                else o.titulo end as titulo_curto,
           -- Quanto custava quando o canal anunciou. E a leitura de preco
           -- imediatamente anterior a publicacao, nao o preco de hoje.
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
    select r.*,
           coalesce(r.preco_publicado, r.preco_atual) as referencia
    from recentes r
    -- Oferta fora do ar nao vira story: o leitor clicaria para encontrar
    -- produto esgotado, e o story sai DEPOIS do post do canal — ou seja, ele e
    -- sempre uma segunda chance de errar.
    --
    -- Preco que voltou a subir, por outro lado, continua aparecendo. Nao e
    -- descuido: a `chamada` carrega `preco_atual`, o preco de hoje, entao o
    -- story sai correto de qualquer jeito. O que a alta muda e o tamanho da
    -- noticia, nao a veracidade dela — por isso vira aviso em `o_preco` e
    -- ordem no fim da fila, e nao exclusao. Quem decide se ainda vale postar
    -- e quem esta olhando.
    where r.disponivel
  )
  select
    a.publicado_em,
    a.titulo_curto,

    -- Fundo do story. Vem da CDN oficial da loja, a mesma que o publicador ja
    -- aceita; pode ser null quando a oferta nao trouxe foto, e ai o story vai
    -- de fundo liso.
    a.url_imagem,

    -- O que digitar por cima da foto. Sem URL, de proposito.
    E'\U0001F525 ' || a.titulo_curto || E'\n\n' ||
    case when a.preco_original is not null and a.preco_original > a.preco_atual
         then 'De R$ ' || public.dinheiro(a.preco_original) || E'\n'
         else '' end ||
    'R$ ' || public.dinheiro(a.preco_atual) ||
    case when a.desconto_percentual is not null
         then ' (-' || to_char(a.desconto_percentual, 'FM990') || '%)'
         else '' end || E'\n\n' ||
    E'Toca no link \U0001F446\n\n' ||
    'PUBLICIDADE • LINK DE AFILIADO',

    -- Vai no sticker de link, nunca no texto.
    a.url_afiliado,

    a.referencia,
    a.preco_atual,

    -- Le antes de postar: se mudou, a arte precisa mudar junto.
    case
      when a.preco_atual > a.referencia then 'SUBIU desde o post — confira antes'
      when a.preco_atual < a.referencia then 'caiu mais ainda'
      else 'mesmo preço do post'
    end
  from ainda_de_pe a
  -- Quem caiu mais primeiro: e o story com a melhor noticia para contar.
  order by (a.preco_atual - a.referencia) asc, a.publicado_em desc;
$$;

comment on function public.para_story(integer) is
  'Ofertas ja publicadas prontas para story: foto, texto sem URL e o link para o sticker. O sticker e colado a mao porque a Graph API nao publica sticker.';

revoke all on function public.para_story(integer) from public, anon;
grant execute on function public.para_story(integer) to service_role, authenticated;
