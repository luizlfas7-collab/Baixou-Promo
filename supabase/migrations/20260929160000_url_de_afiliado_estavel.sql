-- O link de afiliado de uma oferta para de mudar a cada releitura.
--
-- Sintoma que trouxe isto: em 29/09 a primeira publicacao da Shopee em tres
-- dias (publicacao 168, carregador BASIKE) apareceu em integridade_do_link com
-- veredito 'link_trocado' — o primeiro da historia do projeto, que sempre
-- fechou 100% ok.
--
-- Causa: a API da Shopee devolve um short link NOVO a cada chamada para o mesmo
-- produto. A oferta foi revisitada 41 vezes entre a publicacao (00:39) e a
-- deteccao (10:53), e o `on conflict do update` reescrevia url_afiliado em
-- todas. O botao do post guardava o link de 00:39; a tabela guardava o de
-- 10:53; a checagem comparou os dois e acusou divergencia.
--
-- Nao havia perda de dinheiro: os dois links sao s.shopee.com.br com o ID do
-- dono, e o publicado continua creditando. O dano era outro, e pior a prazo:
-- TODA publicacao da Shopee passaria a acusar 'link_trocado' em poucas horas.
-- O alarme que guarda a instrucao permanente "sempre publique em cima do meu
-- link de afiliado" viraria ruido constante — e alarme que grita a toa e
-- alarme que se aprende a ignorar. Perder essa checagem custa mais caro que
-- qualquer comissao isolada.
--
-- Conserto: manter o primeiro link de afiliado conhecido da oferta. Nao ha
-- motivo para trocar — short link de afiliado nao expira, e um link estavel faz
-- o payload publicado e a tabela concordarem sempre, devolvendo sentido a
-- checagem. Se a oferta ainda nao tem link (caso da descoberta do ML, que
-- insere sem url_afiliado), o primeiro que chegar preenche.
--
-- Muda UMA linha do on conflict. Todo o resto de registrar_oferta segue igual.

create or replace function public.registrar_oferta(
  p_fonte_slug text,
  p_id_externo text,
  p_titulo text,
  p_url_canonica text,
  p_preco_atual numeric,
  p_chave_observacao text,
  p_url_afiliado text default null::text,
  p_url_imagem text default null::text,
  p_preco_original numeric default null::numeric,
  p_moeda text default 'BRL'::text,
  p_pontuacao numeric default null::numeric,
  p_payload jsonb default null::jsonb,
  p_raia text default 'confiavel'::text,
  p_metadados jsonb default '{}'::jsonb,
  p_expira_em timestamp with time zone default null::timestamp with time zone
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_cfg public.configuracoes;
  v_fonte public.fontes;
  v_oferta public.ofertas;
  v_agora timestamptz := now();
  v_anterior numeric;
  v_desconto numeric;
  v_elegivel boolean := false;
  v_aprovacao_id bigint;
  v_fila_id bigint;
  v_hash_payload text;
  v_chave_aprovacao text;
  v_versao integer;
  v_motivo text;
begin
  select * into v_cfg from public.configuracoes where id = 1;

  if not found or not v_cfg.coleta_ativa then
    return jsonb_build_object('situacao', 'coleta_desligada');
  end if;

  select * into v_fonte from public.fontes where slug = p_fonte_slug;

  if not found then
    raise exception 'Fonte % nao existe', p_fonte_slug using errcode = 'P0002';
  end if;

  if not v_fonte.habilitada then
    return jsonb_build_object('situacao', 'fonte_desligada', 'fonte', p_fonte_slug);
  end if;

  select h.preco into v_anterior
  from public.historico_precos h
  join public.ofertas o on o.id = h.oferta_id
  where o.fonte_id = v_fonte.id
    and o.id_externo = p_id_externo
    and h.preco > p_preco_atual
  order by h.observado_em desc
  limit 1;

  if v_anterior is not null then
    v_desconto := round(((v_anterior - p_preco_atual) / v_anterior) * 100, 2);
  end if;

  insert into public.ofertas (
    fonte_id, id_externo, titulo, url_canonica, url_afiliado, url_imagem,
    moeda, preco_atual, preco_original, desconto_percentual, pontuacao,
    payload_origem, visto_ultimo_em, expira_em
  )
  values (
    v_fonte.id, p_id_externo, p_titulo, p_url_canonica, p_url_afiliado, p_url_imagem,
    p_moeda, p_preco_atual, p_preco_original, v_desconto, p_pontuacao,
    coalesce(p_metadados, '{}'::jsonb), v_agora, p_expira_em
  )
  on conflict (fonte_id, id_externo) do update
    set titulo = excluded.titulo,
        url_canonica = excluded.url_canonica,
        -- O PRIMEIRO link vale. A Shopee devolve um short link novo a cada
        -- chamada; sobrescrever fazia o post publicado e a tabela divergirem e
        -- disparava 'link_trocado' em toda publicacao da fonte.
        url_afiliado = coalesce(public.ofertas.url_afiliado, excluded.url_afiliado),
        url_imagem = excluded.url_imagem,
        preco_atual = excluded.preco_atual,
        preco_original = excluded.preco_original,
        desconto_percentual = coalesce(excluded.desconto_percentual, public.ofertas.desconto_percentual),
        pontuacao = coalesce(excluded.pontuacao, public.ofertas.pontuacao),
        payload_origem = excluded.payload_origem,
        visto_ultimo_em = excluded.visto_ultimo_em,
        expira_em = excluded.expira_em,
        disponivel = true
  returning * into v_oferta;

  insert into public.historico_precos (
    oferta_id, chave_idempotencia, observado_em, moeda, preco, preco_original, metadados
  )
  values (
    v_oferta.id, p_chave_observacao, v_agora, p_moeda, p_preco_atual, p_preco_original,
    coalesce(p_metadados, '{}'::jsonb)
  )
  on conflict (chave_idempotencia) do nothing;

  if p_payload is null then
    return jsonb_build_object(
      'situacao', 'observada', 'oferta_id', v_oferta.id, 'desconto', v_desconto
    );
  end if;

  if not v_cfg.aprovacao_automatica_ativa then
    v_motivo := 'aprovacao_automatica_desligada';
  elsif v_cfg.destino_padrao = '' then
    v_motivo := 'destino_nao_configurado';
  elsif coalesce(p_pontuacao, 0) < v_cfg.aprovacao_pontuacao_minima then
    v_motivo := 'pontuacao_abaixo_do_minimo';
  elsif p_url_afiliado is null then
    v_motivo := 'sem_link_de_afiliado';
  elsif exists (
    select 1 from public.publicacoes p
    where p.oferta_id = v_oferta.id
      and p.publicado_em > v_agora - make_interval(secs => v_cfg.aprovacao_descanso_item_segundos)
  ) then
    v_motivo := 'item_em_descanso';
  elsif exists (
    select 1 from public.fila_publicacao f
    where f.oferta_id = v_oferta.id
      and f.situacao in ('pendente', 'retentar', 'reservada', 'despachando')
  ) then
    v_motivo := 'ja_esta_na_fila';
  else
    v_elegivel := true;
  end if;

  if not v_elegivel then
    return jsonb_build_object(
      'situacao', 'nao_enfileirada',
      'oferta_id', v_oferta.id,
      'motivo', v_motivo,
      'desconto', v_desconto
    );
  end if;

  update public.ofertas set situacao = 'elegivel' where id = v_oferta.id
    returning * into v_oferta;

  v_chave_aprovacao := format(
    '%s:%s:%s', p_fonte_slug, p_id_externo, left(v_oferta.hash_conteudo, 16)
  );

  if exists (
    select 1 from public.aprovacoes ap where ap.chave_idempotencia = v_chave_aprovacao
  ) then
    return jsonb_build_object(
      'situacao', 'nao_enfileirada',
      'oferta_id', v_oferta.id,
      'motivo', 'conteudo_ja_aprovado',
      'desconto', v_desconto
    );
  end if;

  update public.aprovacoes set vigente = false
    where oferta_id = v_oferta.id and vigente;

  v_hash_payload := encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex');

  insert into public.aprovacoes (
    oferta_id, hash_payload_aprovado, chave_idempotencia, decisao, origem_decisao,
    versao_regra, pontuacao, vigente, decidida_em, expira_em
  )
  values (
    v_oferta.id, v_hash_payload, v_chave_aprovacao,
    'aprovada', 'motor_regras', v_cfg.aprovacao_versao_regra, p_pontuacao, true, v_agora,
    v_agora + make_interval(secs => v_cfg.aprovacao_idade_maxima_segundos)
  )
  on conflict (chave_idempotencia) do nothing
  returning id into v_aprovacao_id;

  if v_aprovacao_id is null then
    return jsonb_build_object(
      'situacao', 'nao_enfileirada',
      'oferta_id', v_oferta.id,
      'motivo', 'conteudo_ja_aprovado',
      'desconto', v_desconto
    );
  end if;

  select coalesce(max(f.versao_conteudo), 0) + 1 into v_versao
  from public.fila_publicacao f
  where f.oferta_id = v_oferta.id
    and f.canal = v_cfg.canal_padrao
    and f.destino = v_cfg.destino_padrao;

  insert into public.fila_publicacao (
    oferta_id, aprovacao_id, hash_conteudo_oferta, canal, destino, versao_conteudo,
    chave_idempotencia, prioridade, payload, hash_payload, raia
  )
  values (
    v_oferta.id, v_aprovacao_id, v_oferta.hash_conteudo,
    v_cfg.canal_padrao, v_cfg.destino_padrao, v_versao,
    format('%s:%s:%s:%s', v_cfg.canal_padrao, v_cfg.destino_padrao, v_oferta.id, v_aprovacao_id),
    least(coalesce(p_pontuacao, 0), 32767)::smallint,
    p_payload, v_hash_payload, p_raia
  )
  returning id into v_fila_id;

  return jsonb_build_object(
    'situacao', 'enfileirada',
    'oferta_id', v_oferta.id,
    'aprovacao_id', v_aprovacao_id,
    'fila_id', v_fila_id,
    'desconto', v_desconto
  );
end;
$function$;

-- Conferencia: a barreira que protege a comissao tem que continuar de pe.
-- Uma oferta sem link nao pode virar fila, e o link existente nao pode sumir.
do $$
declare
  v_perdeu int;
begin
  select count(*) into v_perdeu
  from public.ofertas
  where url_afiliado is null
    and exists (select 1 from public.fila_publicacao f where f.oferta_id = ofertas.id);

  if v_perdeu > 0 then
    raise exception
      '% ofertas ja publicadas ficaram sem url_afiliado; a migracao nao deveria apagar link', v_perdeu;
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'registrar_oferta'
  ) then
    raise exception 'registrar_oferta sumiu';
  end if;
end $$;
