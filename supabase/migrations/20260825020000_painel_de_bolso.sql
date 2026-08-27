-- Painel de bolso
--
-- Uma consulta só, para olhar o Baixou do celular pelo SQL Editor do Supabase,
-- que funciona no navegador do telefone sem instalar nada.
--
-- Existe porque a alternativa é decorar seis funções diferentes e colar uma a
-- uma numa tela pequena. Quem está fora do computador precisa de UMA colagem
-- que responda "está tudo bem?" e "tem algo esperando por mim?".
--
-- A ordem dos campos não é estética: é a ordem em que o problema aparece.
-- Primeiro se o motor está vivo, depois se está travado, depois se está
-- rendendo, e por último o que está prestes a virar post.

create or replace function public.painel()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_saude jsonb;
  v_cfg public.configuracoes;
begin
  v_saude := public.saude_da_coleta();
  select * into v_cfg from public.configuracoes where id = 1;

  return jsonb_build_object(
    -- 1. O motor está vivo?
    'coleta', v_saude->>'veredito',
    'ultima_leitura_min', v_saude->'minutos_desde_a_leitura',
    'leituras_1h', v_saude->'leituras_1h',
    'falhas_1h', v_saude->'falhas_1h',

    -- 2. Está travado?
    'trava_de_emergencia', case when v_cfg.trava_emergencia then 'LIGADA' else 'solta' end,
    'coleta_ativa', v_cfg.coleta_ativa,
    'mercado_livre', (public.ml_conexao_estado())->>'situacao',

    -- 3. Está rendendo?
    'watchlist', v_saude->'itens_na_watchlist',
    'sem_link', v_saude->'itens_sem_link',
    'publicados_24h', (
      select count(*) from public.publicacoes where criado_em > now() - interval '24 hours'
    ),
    'publicados_total', (select count(*) from public.publicacoes),
    'na_fila', (
      select count(*) from public.fila_publicacao
      where situacao in ('pendente', 'retentar', 'reservada', 'despachando')
    ),

    -- 4. O que está perto de virar post
    'quase_la', (
      select coalesce(jsonb_agg(t order by t->>'abaixo' desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'produto', coalesce(i.apelido, i.produto_catalogo),
                 'abaixo', (public.ml_vantagem_de_preco(o.id)->>'abaixo_da_referencia_pct'),
                 'nota', (public.ml_vantagem_de_preco(o.id)->>'competitividade')
               ) as t
        from public.itens_ml i
        join public.ofertas o on o.id_externo = i.produto_catalogo
        where i.habilitado
          and (public.ml_vantagem_de_preco(o.id)->>'competitividade')::int >= 10
        limit 5
      ) s
    )
  );
end;
$$;

comment on function public.painel() is
  'Tudo que importa numa consulta so: select jsonb_pretty(public.painel());';

revoke all on function public.painel() from public, anon;
grant execute on function public.painel() to service_role, authenticated;
