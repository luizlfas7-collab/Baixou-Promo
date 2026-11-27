-- O vigia do banco tinha UMA regra de fonte: veredito in ('cega','muda') — ou
-- seja, so fonte que PAROU de ler. E nao tinha regra nenhuma para destino em
-- quarentena. Esta migracao acrescenta as duas coisas que faltavam, e nada
-- mais: todo o resto do corpo e identico ao que estava no banco.
--
-- REGRA 1 — FONTE DEGRADADA. Fonte que perde metade da capacidade e segue
-- lendo um pouco nunca o acordava. MEDIDO: a Shopee passou de 09 a 16/11
-- lendo 29% a 38% do normal e o vigia, que roda a cada 30 minutos, tem o
-- token no cofre e o chat configurado — portanto TEM VOZ — passou oito dias
-- sem nada a dizer. Hoje, 24/11, a Shopee esta `degradada` em 0,59 outra vez
-- e o vigia continua calado. Isso acaba aqui.
--
-- Esta regra so entra AGORA, e nao em 11/11 quando fontes_degradadas() foi
-- escrita, porque a base dela era mediana movel de 7 dias: afundava junto com
-- a queda e apagava o proprio alarme. Ligar um alarme defeituoso e pior que
-- nao ter alarme, porque cria confianca sem cobertura. A base virou ancora
-- fixa em 20261123234000, validada dia a dia contra 32 dias de historico.
-- Agora a regra pode subir.
--
-- REGRA 2 — DESTINO EM QUARENTENA. Esta e a que doi.
--
-- Em 20/11 02:45 uma foto que o Telegram nao conseguiu baixar devolveu
-- "400 Bad Request: failed to get HTTP URL content". O worker classificou
-- como resultado_desconhecido e poz o destino em quarentena com
-- reservado_ate = 'infinity', que bloqueia TODA reserva. O canal ficou
-- congelado 61 HORAS E MEIA, ate 22/11 16:15. Nesse periodo pelo menos 9
-- ofertas aprovadas com nota entre 88 e 100 entraram na fila e venceram sem
-- nunca serem tocadas (reservada_em nulo, tentativas zero).
--
-- E NADA ALARMOU. A fila nao passava de 50 (a regra de fila nao pegava),
-- publicou_24h nao era zero no comeco (a regra de silencio nao pegava), as
-- duas fontes liam normalmente (as regras de fonte nao pegavam). Quatro
-- guardas, todos olhando para o lado errado, porque nenhum perguntava a
-- pergunta certa: o destino esta aceitando mensagem?
--
-- Quinze minutos e o limite de proposito. Quarentena legitima se resolve em
-- segundos pela reconciliacao do proprio worker; quarentena que passa de 15
-- minutos e dinheiro parado, nao operacao normal. Com esta regra o incidente
-- de 20/11 teria durado 15 minutos em vez de 61 horas.
--
-- O texto do aviso carrega o comando da saida, porque as 3 da manha nao se
-- lembra que soltar_trava() e OUTRO mecanismo (trava_ligada) e nao resolve
-- quarentena nenhuma. Isso me custou tempo em 22/11.
CREATE OR REPLACE FUNCTION public.vigia_do_motor(p_carencia_horas integer DEFAULT 6)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_token       text;
  v_chat        text;
  v_saude       jsonb;
  v_link        jsonb;
  v_token_ml    text;
  v_publicou    integer;
  v_fila        integer;
  v_fonte       record;
  v_abertos     text[] := '{}';
  v_problemas   jsonb  := '[]'::jsonb;
  v_novos       integer := 0;
  v_resolvidos  integer := 0;
  v_pedido      bigint;
  v_carencia    interval := make_interval(hours => greatest(1, coalesce(p_carencia_horas, 6)));
  r             record;
begin
  select c.alerta_telegram_chat_id into v_chat
  from public.configuracoes c where c.id = 1;

  select s.decrypted_secret into v_token
  from vault.decrypted_secrets s
  where s.name = 'baixou_telegram_bot_token';

  if v_token is null or v_chat is null then
    insert into public.erros (
      chave_idempotencia, gravidade, codigo, mensagem, contexto,
      ocorrencias, visto_primeiro_em, visto_ultimo_em
    )
    values (
      'vigia_sem_destino', 'critico', 'vigia_nao_configurado',
      case when v_token is null
           then 'Falta o segredo baixou_telegram_bot_token no Vault. O vigia esta MUDO.'
           else 'Falta configuracoes.alerta_telegram_chat_id. O vigia esta MUDO.' end,
      jsonb_build_object('tem_token', v_token is not null, 'tem_chat', v_chat is not null),
      1, now(), now()
    )
    on conflict (chave_idempotencia) do update
      set ocorrencias = public.erros.ocorrencias + 1,
          visto_ultimo_em = now(),
          resolvido_em = null;

    return jsonb_build_object(
      'situacao', 'vigia_mudo',
      'tem_token', v_token is not null,
      'tem_chat', v_chat is not null
    );
  end if;

  update public.erros set resolvido_em = now()
   where chave_idempotencia = 'vigia_sem_destino' and resolvido_em is null;

  v_saude := public.saude_da_coleta();
  v_link  := public.integridade_do_link(48);

  select cm.situacao into v_token_ml from public.credenciais_ml cm;

  select count(*) into v_publicou
  from public.publicacoes p where p.publicado_em > now() - interval '24 hours';

  -- Conta pela funcao, nunca a mao: public.fila_pendente() sabe quais estados
  -- sao terminais (publicada, descartada e TAMBEM cancelada). Aqui a conta era
  -- a mao e esquecia cancelada, entao reportava 7 com a fila realmente vazia,
  -- e a regra de cegueira deste proprio vigia nunca podia disparar.
  select public.fila_pendente() into v_fila;

  -- REGRA NOVA: destino que nao aceita mensagem. Primeira da lista porque e a
  -- unica que para o canal INTEIRO: com reservado_ate = 'infinity' nenhum
  -- item consegue ser reservado, e oferta aprovada vence sem ser tocada.
  for r in
    select d.canal, d.destino, d.quarentena_motivo,
           extract(epoch from (now() - d.quarentena_em)) / 60.0 as minutos
    from public.estado_destino d
    where d.quarentena_em is not null
      and d.quarentena_em < now() - interval '15 minutes'
  loop
    v_problemas := v_problemas || jsonb_build_object(
      'chave', 'quarentena:' || r.canal || ':' || r.destino,
      'texto', format(
        'CANAL PARADO: o destino %s (%s) esta em quarentena ha %s minutos. Motivo gravado: %s. Enquanto isso NENHUM item pode ser reservado e oferta aprovada vence sem publicar. Conferir no canal se a ultima mensagem saiu e soltar com reconciliar_destino(''%s'', ''%s'', ''entregue'' ou ''nao_entregue''). soltar_trava() NAO resolve isso: e outro mecanismo.',
        r.destino, r.canal, round(r.minutos),
        coalesce(r.quarentena_motivo, 'nenhum'),
        r.canal, r.destino));
  end loop;

  if coalesce((v_link->>'ok')::int, 0) < coalesce((v_link->>'publicacoes')::int, 0) then
    v_problemas := v_problemas || jsonb_build_object(
      'chave', 'link',
      'texto', format('DINHEIRO: %s de %s publicacoes com link suspeito (trocado %s, sem link %s, fora do dominio %s). Comissao pode estar indo embora.',
             (v_link->>'publicacoes')::int - (v_link->>'ok')::int,
             v_link->>'publicacoes', v_link->>'link_trocado',
             v_link->>'sem_link', v_link->>'fora_do_dominio'));
  end if;

  for v_fonte in
    select key as slug, value as dados
    from jsonb_each(coalesce(v_saude->'por_fonte', '{}'::jsonb))
  loop
    if v_fonte.dados->>'veredito' in ('cega', 'muda') then
      v_problemas := v_problemas || jsonb_build_object(
        'chave', 'fonte:' || v_fonte.slug,
        'texto', format('MOTOR CEGO: a fonte %s esta "%s". Ultima leitura ha %s minutos. Nada esta sendo captado.',
               v_fonte.slug, v_fonte.dados->>'veredito',
               round(coalesce((v_fonte.dados->>'minutos_desde_a_leitura')::numeric, 0))));
    end if;
  end loop;

  if v_token_ml is null or v_token_ml not in ('pronta', 'renovando') then
    v_problemas := v_problemas || jsonb_build_object(
      'chave', 'token_ml',
      'texto', format('CREDENCIAL: o token do Mercado Livre esta "%s". Sem ele o ML para de captar.',
             coalesce(v_token_ml, 'ausente')));
  end if;

  if v_publicou = 0 and v_fila = 0 then
    v_problemas := v_problemas || jsonb_build_object(
      'chave', 'sem_publicacao',
      'texto', 'SEM PUBLICAR: 24h sem nenhum post e com a fila vazia. O motor le, mas nada passa da barra.');
  end if;

  if v_saude->>'revisita_veredito' = 'esticada' then
    v_problemas := v_problemas || jsonb_build_object(
      'chave', 'revisita',
      'texto', format('LENTO: a revisita subiu para %sh. Queda relampago passa sem ser vista.',
             v_saude->>'revisita_horas'));
  end if;

  if v_fila > 50 then
    v_problemas := v_problemas || jsonb_build_object(
      'chave', 'fila',
      'texto', format('FILA: %s itens aprovados e nao publicados. O publicador pode estar parado.', v_fila));
  end if;

  -- Fonte que LE e nao ENTREGA. Ver entrega_por_fonte().
  v_problemas := v_problemas || public.entrega_por_fonte();

  -- REGRA NOVA: fonte que ainda le, mas MUITO menos do que o normal dela.
  -- Base ancorada (ver referencia_de_leitura), nao mediana movel.
  v_problemas := v_problemas || public.fontes_degradadas();

  v_problemas := v_problemas || public.aprovacoes_vencidas(24);
  select coalesce(array_agg(x->>'chave'), '{}') into v_abertos
  from jsonb_array_elements(v_problemas) x;

  for r in
    select x->>'chave' as chave, x->>'texto' as texto
    from jsonb_array_elements(v_problemas) x
  loop
    if not exists (
      select 1 from public.alertas_enviados e
       where e.chave = r.chave and e.ultimo_envio_em > now() - v_carencia
    ) then
      select net.http_post(
        url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
        body := jsonb_build_object(
          'chat_id', v_chat,
          'text', '[BAIXOU] ' || r.texto,
          'disable_web_page_preview', true
        )
      ) into v_pedido;

      insert into public.alertas_enviados (chave, texto, pedido_id)
      values (r.chave, r.texto, v_pedido)
      on conflict (chave) do update
        set texto = excluded.texto,
            ultimo_envio_em = now(),
            envios = public.alertas_enviados.envios + 1,
            pedido_id = excluded.pedido_id;

      v_novos := v_novos + 1;
    end if;
  end loop;

  for r in
    select e.chave, e.texto, e.envios, e.primeiro_envio_em
    from public.alertas_enviados e
    where not (e.chave = any (v_abertos))
  loop
    select net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      body := jsonb_build_object(
        'chat_id', v_chat,
        'text', format('[BAIXOU] NORMALIZADO apos %s: %s',
                       age(now(), r.primeiro_envio_em)::text, r.texto),
        'disable_web_page_preview', true
      )
    ) into v_pedido;

    delete from public.alertas_enviados where chave = r.chave;
    v_resolvidos := v_resolvidos + 1;
  end loop;

  return jsonb_build_object(
    'situacao', 'ok',
    'problemas_agora', coalesce(array_length(v_abertos, 1), 0),
    'avisos_enviados', v_novos,
    'normalizados', v_resolvidos,
    'abertos', v_abertos,
    'publicou_24h', v_publicou,
    'fila_pendente', v_fila
  );
end;
$function$;
