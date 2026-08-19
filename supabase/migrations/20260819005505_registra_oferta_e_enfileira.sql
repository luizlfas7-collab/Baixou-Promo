-- ---------------------------------------------------------------------------
-- registrar_oferta: a porta de entrada dos coletores.
--
-- Grava a oferta e a observacao de preco, e — quando as porteiras permitem —
-- cria a aprovacao e enfileira a mensagem que o coletor ja montou.
--
-- O texto vem pronto de fora (montado em TypeScript, testavel). O banco nao
-- monta mensagem: ele decide se pode publicar e amarra o payload a versao
-- exata da oferta aprovada.
-- ---------------------------------------------------------------------------
create function public.registrar_oferta(
  p_fonte_slug text,
  p_id_externo text,
  p_titulo text,
  p_url_canonica text,
  p_preco_atual numeric,
  p_chave_observacao text,
  p_url_afiliado text default null,
  p_url_imagem text default null,
  p_preco_original numeric default null,
  p_moeda text default 'BRL',
  p_pontuacao numeric default null,
  p_payload jsonb default null,
  p_raia text default 'confiavel',
  p_metadados jsonb default '{}'::jsonb,
  p_expira_em timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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

  -- Desconto so e afirmado com base no que o proprio banco observou.
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
        url_afiliado = excluded.url_afiliado,
        url_imagem = excluded.url_imagem,
        preco_atual = excluded.preco_atual,
        preco_original = excluded.preco_original,
        desconto_percentual = excluded.desconto_percentual,
        pontuacao = excluded.pontuacao,
        payload_origem = excluded.payload_origem,
        visto_ultimo_em = excluded.visto_ultimo_em,
        expira_em = excluded.expira_em,
        disponivel = true
  returning * into v_oferta;

  -- Observacao de preco: repetir a mesma chave nao duplica nada.
  insert into public.historico_precos (
    oferta_id, chave_idempotencia, observado_em, moeda, preco, preco_original, metadados
  )
  values (
    v_oferta.id, p_chave_observacao, v_agora, p_moeda, p_preco_atual, p_preco_original,
    coalesce(p_metadados, '{}'::jsonb)
  )
  on conflict (chave_idempotencia) do nothing;

  -- Sem mensagem montada, o coletor esta apenas observando.
  if p_payload is null then
    return jsonb_build_object(
      'situacao', 'observada', 'oferta_id', v_oferta.id, 'desconto', v_desconto
    );
  end if;

  -- ---------------------------------------------------------------------
  -- Porteiras de publicacao.
  -- ---------------------------------------------------------------------
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

  -- So pode haver uma aprovacao vigente por oferta.
  update public.aprovacoes set vigente = false
    where oferta_id = v_oferta.id and vigente;

  v_hash_payload := encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex');

  insert into public.aprovacoes (
    oferta_id, hash_payload_aprovado, chave_idempotencia, decisao, origem_decisao,
    versao_regra, pontuacao, vigente, decidida_em, expira_em
  )
  values (
    v_oferta.id, v_hash_payload,
    format('%s:%s:%s', p_fonte_slug, p_id_externo, left(v_oferta.hash_conteudo, 16)),
    'aprovada', 'motor_regras', v_cfg.aprovacao_versao_regra, p_pontuacao, true, v_agora,
    v_agora + make_interval(secs => v_cfg.aprovacao_idade_maxima_segundos)
  )
  returning id into v_aprovacao_id;

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
$$;

revoke execute on function public.registrar_oferta(
  text, text, text, text, numeric, text, text, text, numeric, text, numeric,
  jsonb, text, jsonb, timestamptz
) from anon, authenticated, public;

grant execute on function public.registrar_oferta(
  text, text, text, text, numeric, text, text, text, numeric, text, numeric,
  jsonb, text, jsonb, timestamptz
) to service_role;
