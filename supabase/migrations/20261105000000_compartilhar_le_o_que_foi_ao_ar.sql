-- ---------------------------------------------------------------------------
-- O pacote de compartilhamento mentia o preco.
--
-- para_compartilhar() montava o texto de WhatsApp/Instagram/X a partir de
-- o.preco_atual, o.preco_original e o.desconto_percentual — as colunas VIVAS
-- da oferta. Mas o preco segue mudando depois da publicacao, entao o texto
-- divergia do que foi ao ar. Medido em 04/11:
--
--   Air Fryer WAP Barbecue   Telegram R$ 1.049,90   pacote R$ 1.799,00
--   Fritadeira Mondial 12L   Telegram R$   428,90   pacote R$   449,90
--   Parafusadeira WAP K21    Telegram R$   249,89   pacote R$   308,36
--   Aspirador WAP GTW 10     Telegram R$   200,00   pacote R$   149,99
--
-- Os NOVE textos das ultimas 24h estavam errados. Colar isso num canal e
-- publicar preco falso no link de afiliado do dono: o leitor clica, acha
-- outro valor, e a conta de confianca quem paga e ele.
--
-- E a MESMA armadilha que o boletim tomou em 01/10 e que foi consertada la
-- (20261006120000: "Le snapshot_payload, nunca preco_atual"). Esta funcao
-- nasceu em 02/09, antes da licao, e nunca recebeu o conserto.
--
-- Dois defeitos a mais vinham do mesmo lugar, e caem junto:
--   - desconto_percentual 0,01 virava "0% abaixo do que ja vimos" — anuncio
--     de promocao de zero por cento (mochila ROMANTIC CROWN).
--   - "De R$ 1.827,00 por R$ 1.799,00" ao lado de "42% abaixo": o de/por vem
--     das colunas vivas e a porcentagem de outra coluna, na mesma mensagem.
--
-- POR QUE CONVERTER O SNAPSHOT EM VEZ DE RECALCULAR:
--
-- publicacoes.snapshot_payload guarda o payload que FOI enviado — o texto
-- renderizado e o link no botao. Nao tem campo de preco para reler, e isso e
-- uma vantagem: nao existe numero para divergir. Convertendo o texto, o
-- WhatsApp recebe exatamente a mesma noticia do Telegram, sempre.
--
-- A conversao espelha montarRepasseWhatsapp() em _compartilhado/whatsapp.ts,
-- que ja faz isso certo no repasse ao vivo:
--   1. WhatsApp nao entende HTML: <b> vira *, <s> vira ~.
--   2. WhatsApp nao tem botao, entao a URL do botao entra no corpo. Ela vem
--      do proprio snapshot, ou seja ja passou pela allowlist de afiliado na
--      hora de publicar.
--   3. A linha PUBLICIDADE ja esta dentro do texto publicado. Nao se
--      acrescenta de novo: so vira italico.
--
-- O ideal seria uma implementacao so, em TypeScript. Nao e esta mudanca:
-- aqui o objetivo e parar de mentir preco, uma coisa por vez. Fica registrado
-- que as duas existem e que a de SQL e a que deriva.
-- ---------------------------------------------------------------------------

create or replace function public.texto_publicado_para_whatsapp(p_snapshot jsonb)
returns text
language sql
immutable
set search_path to ''
as $$
  with bruto as (
    select coalesce(p_snapshot->>'text', p_snapshot->>'caption', '') as t,
           p_snapshot #>> '{reply_markup,inline_keyboard,0,0,url}' as url
  ),
  convertido as (
    select
      -- <b>x</b> -> *x*, <s>x</s> -> ~x~, e qualquer outra tag sai fora.
      regexp_replace(
        regexp_replace(
          regexp_replace(b.t, '</?b>', '*', 'gi'),
          '</?s>', '~', 'gi'),
        '</?[a-z][^>]*>', '', 'gi') as t,
      b.url
    from bruto b
  )
  select case
           when c.t = '' then null
           else
             -- A linha de PUBLICIDADE ja vem no texto: vira italico no lugar.
             replace(c.t,
                     'PUBLICIDADE • LINK DE AFILIADO',
                     '_PUBLICIDADE • LINK DE AFILIADO_')
             -- URL no corpo porque o WhatsApp nao tem botao. Vai ANTES da
             -- linha de publicidade? Nao: o app so gera previa do ULTIMO
             -- link, e a previa e o que faz o leitor clicar.
             || coalesce(E'\n\n\U0001F449 ' || c.url, '')
         end
  from convertido c;
$$;

revoke execute on function public.texto_publicado_para_whatsapp(jsonb) from anon, authenticated, public;

comment on function public.texto_publicado_para_whatsapp(jsonb) is
  'Converte o payload publicado no Telegram para o formato do WhatsApp. '
  'Espelha montarRepasseWhatsapp() de _compartilhado/whatsapp.ts. Nao '
  'recalcula preco: le o texto que foi ao ar, entao nao existe numero para '
  'divergir do canal.';

-- ---------------------------------------------------------------------------

-- O tipo de retorno muda: as colunas preco e desconto saem. Elas eram
-- justamente os numeros que divergiam, e nao ha de onde reler preco no
-- snapshot: o que foi ao ar e TEXTO. Nao havendo numero, nao ha divergencia.
-- Ninguem chama esta funcao em codigo (so comentarios e grants), verificado
-- em 04/11, entao dropar e seguro.
drop function if exists public.para_compartilhar(integer);

create function public.para_compartilhar(p_horas integer default 24)
returns table (
  publicado_em timestamptz,
  produto text,
  link text,
  whatsapp text,
  instagram text,
  para_o_x text
)
language sql
stable
security definer
set search_path to ''
as $$
  with recentes as (
    select p.publicado_em,
           p.snapshot_payload,
           -- O link sai do snapshot, nao de ofertas.url_afiliado: e o link
           -- que FOI publicado, e ja passou pela allowlist naquela hora.
           p.snapshot_payload #>> '{reply_markup,inline_keyboard,0,0,url}' as url_publicada,
           case when char_length(o.titulo) > 70
                then left(o.titulo, 67) || '...'
                else o.titulo end as titulo_curto
    from public.publicacoes p
    join public.ofertas o on o.id = p.oferta_id
    where p.publicado_em > now() - make_interval(hours => greatest(1, coalesce(p_horas, 24)))
      and p.snapshot_payload #>> '{reply_markup,inline_keyboard,0,0,url}' is not null
  ),
  -- O texto sem marcacao serve de base para Instagram e X, que nao tem
  -- negrito. Tirar as tags aqui evita repetir o regexp tres vezes.
  limpo as (
    select r.*,
           regexp_replace(coalesce(r.snapshot_payload->>'text',
                                   r.snapshot_payload->>'caption', ''),
                          '</?[a-z][^>]*>', '', 'gi') as texto_puro
    from recentes r
  )
  select
    l.publicado_em,
    l.titulo_curto,
    l.url_publicada,

    public.texto_publicado_para_whatsapp(l.snapshot_payload),

    -- Instagram: link nao clica na legenda, entao manda para a bio em vez de
    -- fingir que funciona ali. A URL publicada NAO entra no texto.
    l.texto_puro || E'\n\nLink na bio \U0001F517\n\n'
      || '#promocao #oferta #desconto #achadinhos #baixou',

    -- X: 280 caracteres contando o link.
    left(l.texto_puro || E'\n' || l.url_publicada, 280)
  from limpo l
  order by l.publicado_em desc;
$$;

-- Mesmos grants de 20260902010000: apertar permissao nao e parte deste
-- conserto, e mudanca de seguranca entra sozinha ou nao entra.
revoke all on function public.para_compartilhar(integer) from public, anon;
grant execute on function public.para_compartilhar(integer) to service_role, authenticated;

comment on function public.para_compartilhar(integer) is
  'As ofertas ja publicadas, vestidas para WhatsApp, Instagram e X. Le o '
  'snapshot publicado, NUNCA preco_atual: em 04/11 os nove textos das ultimas '
  '24h divergiam do canal porque recalculavam das colunas vivas da oferta. '
  'Quem publica e o dono, a mao: o WhatsApp nao tem API de canal.';

-- ---------------------------------------------------------------------------
-- Guarda: se alguem reintroduzir preco_atual aqui, isso falha na migracao.
-- ---------------------------------------------------------------------------

do $$
begin
  if pg_get_functiondef('public.para_compartilhar(integer)'::regprocedure)
       ilike '%preco_atual%' then
    raise exception 'para_compartilhar voltou a ler preco_atual: o texto do '
                    'WhatsApp divergiria do que foi publicado no canal';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- AINDA ABERTO: resumo_do_dia() tem o MESMO defeito.
--
-- Ela le o.preco_atual, o.desconto_percentual e o.url_afiliado das colunas
-- vivas, igual. Nao entra nesta migracao porque o conserto dela e diferente:
-- o resumo precisa de uma linha curta por oferta, e o snapshot nao tem campo
-- de preco para reler — teria que extrair a linha do texto publicado. Uma
-- coisa por vez, e ninguem chama resumo_do_dia em codigo hoje.
-- ---------------------------------------------------------------------------
