-- O guarda-costas passa a morar dentro do banco.
--
-- POR QUE ISTO EXISTE
--
-- Ate hoje a vigilancia do Baixou vivia numa sessao de assistente e num
-- conector. Os dois caem. Em 22-27/09 ficaram CINCO DIAS sem ninguem conseguir
-- olhar o motor, e ninguem soube — nao houve alarme porque o que deveria
-- alarmar era justamente o que estava fora do ar. Em 30/09 o conector caiu de
-- novo no meio de uma conversa, ao vivo.
--
-- Vigia que depende da mesma infraestrutura que ele vigia nao e vigia.
--
-- Este roda no pg_cron, le o proprio banco e fala direto com a API do Telegram
-- pelo pg_net. Nao passa por sessao, nao passa por conector, nao passa por
-- assistente nenhum. Se o motor morrer as 3 da manha, o celular do dono apita.
--
-- TRES CUIDADOS QUE DECIDEM SE ELE PRESTA
--
-- 1. Nao repetir. Um alarme que grita a cada 30 minutos e um alarme que se
--    aprende a silenciar. Cada problema tem chave propria e so volta a falar
--    depois da carencia.
--
-- 2. Avisar quando passar. Alarme que nunca diz "voltou ao normal" obriga o
--    dono a ir conferir na mao — que e exatamente o trabalho que ele nao tem
--    que ter.
--
-- 3. Nunca falhar calado. Se o token nao estiver no Vault, isso vira linha na
--    tabela de erros, nao um retorno vazio. A falha do vigia tem que ser tao
--    visivel quanto a falha que ele vigia.

-- ---------------------------------------------------------------------------
-- Para onde avisar
-- ---------------------------------------------------------------------------

alter table public.configuracoes
  add column if not exists alerta_telegram_chat_id text;

comment on column public.configuracoes.alerta_telegram_chat_id is
  'Conversa PRIVADA do dono com o bot. Nunca o canal: alarme no canal e '
  'problema interno virando post para os seguidores.';

update public.configuracoes
   set alerta_telegram_chat_id = '8660036653'
 where id = 1 and alerta_telegram_chat_id is null;

-- ---------------------------------------------------------------------------
-- Memoria do que ja foi avisado
-- ---------------------------------------------------------------------------

create table if not exists public.alertas_enviados (
  chave              text primary key,
  texto              text        not null,
  primeiro_envio_em  timestamptz not null default now(),
  ultimo_envio_em    timestamptz not null default now(),
  envios             integer     not null default 1,
  pedido_id          bigint
);

comment on table public.alertas_enviados is
  'Um problema aberto por linha. A linha nasce quando o alarme dispara e morre '
  'quando o problema passa — e a morte dela e que manda o aviso de normalizado.';

-- ---------------------------------------------------------------------------
-- O vigia
-- ---------------------------------------------------------------------------

create or replace function public.vigia_do_motor(
  p_carencia_horas integer default 6
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
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
  v_chave       text;
  v_texto       text;
  v_pedido      bigint;
  v_carencia    interval := make_interval(hours => greatest(1, coalesce(p_carencia_horas, 6)));
  r             record;
begin
  select c.alerta_telegram_chat_id into v_chat
  from public.configuracoes c where c.id = 1;

  select s.decrypted_secret into v_token
  from vault.decrypted_secrets s
  where s.name = 'baixou_telegram_bot_token';

  -- Falha do vigia vira erro registrado, nunca retorno vazio.
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

  select count(*) into v_fila
  from public.fila_publicacao f where f.situacao not in ('publicada', 'descartada');

  -- ---- Levantar o que esta errado AGORA -------------------------------------
  -- Acumulado em jsonb, e nao em tabela temporaria: esta funcao roda com
  -- search_path vazio, e a resolucao de pg_temp nesse caso nao e garantida.
  -- Um vigia que quebra por detalhe de schema e pior que nao ter vigia.

  -- 1. DINHEIRO: link publicado diferente do cadastrado, ou fora da allowlist.
  if coalesce((v_link->>'ok')::int, 0) < coalesce((v_link->>'publicacoes')::int, 0) then
    v_problemas := v_problemas || jsonb_build_object(
      'chave', 'link',
      'texto', format('DINHEIRO: %s de %s publicacoes com link suspeito (trocado %s, sem link %s, fora do dominio %s). Comissao pode estar indo embora.',
             (v_link->>'publicacoes')::int - (v_link->>'ok')::int,
             v_link->>'publicacoes', v_link->>'link_trocado',
             v_link->>'sem_link', v_link->>'fora_do_dominio'));
  end if;

  -- 2. CEGUEIRA por fonte.
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

  -- 3. TOKEN do Mercado Livre.
  if v_token_ml is null or v_token_ml not in ('pronta', 'renovando') then
    v_problemas := v_problemas || jsonb_build_object(
      'chave', 'token_ml',
      'texto', format('CREDENCIAL: o token do Mercado Livre esta "%s". Sem ele o ML para de captar.',
             coalesce(v_token_ml, 'ausente')));
  end if;

  -- 4. Motor vivo e mudo: le, mas nada chega ao canal e nada espera na fila.
  if v_publicou = 0 and v_fila = 0 then
    v_problemas := v_problemas || jsonb_build_object(
      'chave', 'sem_publicacao',
      'texto', 'SEM PUBLICAR: 24h sem nenhum post e com a fila vazia. O motor le, mas nada passa da barra.');
  end if;

  -- 5. Revisita esticada: a watchlist cresceu mais que a vazao de leitura.
  if v_saude->>'revisita_veredito' = 'esticada' then
    v_problemas := v_problemas || jsonb_build_object(
      'chave', 'revisita',
      'texto', format('LENTO: a revisita subiu para %sh. Queda relampago passa sem ser vista.',
             v_saude->>'revisita_horas'));
  end if;

  -- 6. Fila represada de verdade (lembrando que a tabela e livro-caixa).
  if v_fila > 50 then
    v_problemas := v_problemas || jsonb_build_object(
      'chave', 'fila',
      'texto', format('FILA: %s itens aprovados e nao publicados. O publicador pode estar parado.', v_fila));
  end if;

  select coalesce(array_agg(x->>'chave'), '{}') into v_abertos
  from jsonb_array_elements(v_problemas) x;

  -- ---- Avisar o que e novo ou ja passou da carencia -------------------------
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

  -- ---- Avisar o que voltou ao normal ----------------------------------------
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

comment on function public.vigia_do_motor(integer) is
  'Vigilancia que nao depende de sessao nem de conector. Roda no pg_cron, le o '
  'banco e fala direto com o Telegram pelo pg_net.';

revoke all on function public.vigia_do_motor(integer) from public, anon, authenticated;
grant execute on function public.vigia_do_motor(integer) to service_role;

alter table public.alertas_enviados enable row level security;

-- ---------------------------------------------------------------------------
-- Agendamento: de meia em meia hora, fora dos minutos cheios onde tudo dispara
-- ---------------------------------------------------------------------------

select cron.schedule('baixou-vigia', '13,43 * * * *', $cron$select public.vigia_do_motor(6)$cron$);

-- Conferencia: o vigia tem que existir, estar agendado, e o destino gravado.
do $$
declare
  v_chat text;
begin
  if to_regprocedure('public.vigia_do_motor(integer)') is null then
    raise exception 'vigia_do_motor nao foi criada';
  end if;

  if not exists (select 1 from cron.job where jobname = 'baixou-vigia' and active) then
    raise exception 'o agendamento baixou-vigia nao ficou ativo';
  end if;

  select alerta_telegram_chat_id into v_chat from public.configuracoes where id = 1;
  if v_chat is null then
    raise exception 'alerta_telegram_chat_id ficou nulo; o vigia nasceria mudo';
  end if;
end $$;
