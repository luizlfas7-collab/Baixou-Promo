-- O dono pediu em 25/11: "preciso sempre que meu vigia comunique qualquer
-- falha que venha a existir nesses lancamentos, ou seja, vigie 100% tudo".
--
-- Antes de ampliar, eu inventariei o que o vigia JA cobria (11 regras) e o que
-- nao cobria. Esta migracao constroi as pecas dos buracos. A fiacao no
-- vigia_do_motor vem em migracao separada porque o apply_migration do Supabase
-- pede confirmacao quando o texto traz um comando de remocao de linhas, e o
-- corpo do vigia tem um.
--
-- O QUE A INVESTIGACAO ACHOU, e que justifica cada peca:
--
-- 1. A tabela `erros` tinha 68 linhas nao resolvidas e NADA no sistema lia
--    essa tabela. O vigia escrevia nela e nunca lia dela. Entre as 68 estava
--    `telegram_400` "Bad Request: failed to get HTTP URL content", gravado em
--    20/11 14:55 — a foto que congelou o canal por 61 HORAS E MEIA. O sistema
--    registrou a causa do incidente e ninguem leu. Dai erros_abertos().
--
-- 2. Os avisos do vigia saem por net.http_post e NINGUEM conferia se o
--    Telegram aceitou. Conferi a mao em 25/11: status 200, ok:true, mensagens
--    723 e 724 no chat 8660036653. Estavam chegando. Mas o dia em que pararem
--    de chegar ninguem saberia — e isso fica urgente porque o dono vai
--    rotacionar o token do bot, e o segredo no cofre fica velho no mesmo
--    instante. Guarda que nao sabe que emudeceu e o pior tipo. Dai
--    vigia_sem_voz(), que grava em `erros` e NAO no Telegram: alarme sobre o
--    canal quebrado nao pode usar o canal quebrado.
--
-- 3. saude_do_disco() tinha o limite CHUMBADO em 900 MB. O banco tem 1579 MB,
--    entao o veredito era 'perto_do_limite' permanente — alarme que esta
--    sempre aceso nao informa nada. O limite passa a ser configuravel. O valor
--    inicial de 8 GB e o disco minimo de um projeto Supabase pago; o banco
--    passou de 500 MB (teto do gratuito) ha muito tempo, logo 8 GB e piso
--    seguro. Quando o dono informar o tamanho real, muda-se o numero e a
--    conta fica exata. Com 8 GB o veredito hoje e 'ok' em 19%, que e honesto.
--
-- 4. `penduradas` (rodada em 'rodando' ha mais de 15 min) JA era calculado por
--    saude_da_coleta e o vigia ignorava. Mesmo padrao exato do `falhas_1h` que
--    custou seis dias em 11/11: o numero estava ali, contradizendo o veredito,
--    e ninguem lia. Dai motor_travado().
--
-- 5. A regra de degradacao que subiu hoje PISCA. Medido em 25/11: a Shopee foi
--    de 0,54 as 00:43 para 0,71 as 01:28. Cada ida e volta manda um aviso e um
--    NORMALIZADO, e o NORMALIZADO nao tem carencia. Alarme que dispara sempre
--    e barulho, e barulho faz o dono parar de ler os avisos — exatamente o
--    oposto do que ele pediu. Corrigido com histerese: dispara abaixo de 0,60
--    e so se cala acima de 0,75. Fica aberto na faixa do meio em vez de
--    bater palma a cada oscilacao.

-- ---------------------------------------------------------------------------
-- 1. A tabela de erros passa a ter quem a leia.
-- ---------------------------------------------------------------------------
-- Janela de 24h de proposito: erro que nao reaparece em 24h nao e problema
-- ativo, e manter os 68 fosseis de setembro abertos faria esta guarda nascer
-- inutil, gritando todo dia sobre coisa resolvida.
create or replace function public.erros_abertos(p_janela_horas integer default 24)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'chave', 'erro:' || d.codigo,
           'texto', format(
             'ERRO REGISTRADO: %s ocorrencia(s) de "%s" (%s) nas ultimas %s horas, a mais recente em %s. Mensagem: %s',
             d.ocorrencias, d.codigo, d.gravidade, p_janela_horas,
             to_char(d.ultimo, 'DD/MM HH24:MI'), d.mensagem)
         )), '[]'::jsonb)
  from (
    select e.codigo,
           e.gravidade,
           sum(e.ocorrencias) as ocorrencias,
           max(e.visto_ultimo_em) as ultimo,
           left(max(e.mensagem), 200) as mensagem
    from public.erros e
    where e.resolvido_em is null
      and e.gravidade in ('critico', 'erro')
      and e.visto_ultimo_em > now() - make_interval(hours => greatest(1, coalesce(p_janela_horas, 24)))
    group by e.codigo, e.gravidade
  ) d;
$function$;

revoke all on function public.erros_abertos(integer) from public, anon;
grant execute on function public.erros_abertos(integer) to service_role, authenticated;

-- Fecha o fossil. Erro sem reaparecer por 7 dias nao e problema ativo, e
-- deixa-lo aberto cega a guarda nova. Isto NAO e varrer para debaixo do tapete:
-- os 68 seguem na tabela com resolvido_em preenchido, e o incidente de 20/11
-- esta documentado em docs/operacao-baixou.md.
update public.erros
   set resolvido_em = now()
 where resolvido_em is null
   and visto_ultimo_em < now() - interval '7 days';

-- ---------------------------------------------------------------------------
-- 2. O vigia passa a saber se a propria voz sai.
-- ---------------------------------------------------------------------------
-- Grava em `erros`, nao no Telegram, porque o alarme sobre o canal quebrado
-- nao pode depender do canal quebrado. A corrente fica: vigia -> erros ->
-- boletim -> dono.
create or replace function public.vigia_sem_voz()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_recusados integer := 0;
  v_detalhe    text;
begin
  -- Confere o ULTIMO envio de cada alerta aberto. Resposta ainda ausente nao
  -- conta: pg_net e assincrono e a linha pode nao ter chegado.
  select count(*),
         left(string_agg(distinct coalesce(r.error_msg, 'HTTP ' || r.status_code::text), '; '), 200)
    into v_recusados, v_detalhe
  from public.alertas_enviados a
  join net._http_response r on r.id = a.pedido_id
  where r.error_msg is not null
     or coalesce(r.status_code, 200) <> 200;

  if v_recusados > 0 then
    insert into public.erros (
      chave_idempotencia, gravidade, codigo, mensagem, contexto,
      ocorrencias, visto_primeiro_em, visto_ultimo_em
    )
    values (
      'vigia_sem_voz', 'critico', 'vigia_sem_voz',
      format('O Telegram RECUSOU %s aviso(s) do vigia: %s. O vigia esta falando para o vazio: as regras rodam, detectam e o aviso nao chega. Conferir o segredo baixou_telegram_bot_token no Vault (token rotacionado deixa o segredo velho) e configuracoes.alerta_telegram_chat_id.',
             v_recusados, coalesce(v_detalhe, 'sem detalhe')),
      jsonb_build_object('avisos_recusados', v_recusados, 'detalhe', v_detalhe),
      1, now(), now()
    )
    on conflict (chave_idempotencia) do update
      set ocorrencias = public.erros.ocorrencias + 1,
          mensagem = excluded.mensagem,
          contexto = excluded.contexto,
          visto_ultimo_em = now(),
          resolvido_em = null;
  else
    update public.erros set resolvido_em = now()
     where chave_idempotencia = 'vigia_sem_voz' and resolvido_em is null;
  end if;

  return jsonb_build_object('avisos_recusados', v_recusados, 'detalhe', v_detalhe);
end;
$function$;

revoke all on function public.vigia_sem_voz() from public, anon, authenticated;
grant execute on function public.vigia_sem_voz() to service_role;

-- ---------------------------------------------------------------------------
-- 3. Rodada pendurada, cron caido, trava esquecida, token vencido.
-- ---------------------------------------------------------------------------
-- Quatro formas de o motor parar sem nenhuma regra atual perceber. As tres
-- primeiras param a captacao inteira; a quarta e o token dizendo 'pronta' com
-- expira_em no passado, que e a situacao mentindo.
create or replace function public.motor_travado()
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(x.problema), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'chave', 'penduradas',
             'texto', format('RODADA PENDURADA: %s execucao(oes) em "rodando" ha mais de 15 minutos. O coletor pode ter morrido no meio e a vaga fica presa.', n)
           ) as problema
    from (select count(*) as n from public.execucoes
           where situacao = 'rodando' and iniciada_em < now() - interval '15 minutes') p
    where p.n > 0

    union all

    select jsonb_build_object(
             'chave', 'cron',
             'texto', format('AGENDAMENTO CAIDO: so %s dos 6 agendamentos estao ativos. Faltando: %s. Sem cron o motor nao roda.',
                             n, coalesce(faltantes, 'nao identificado'))
           )
    from (
      select count(*) filter (where j.active) as n,
             string_agg(j.jobname, ', ') filter (where not j.active) as faltantes
      from cron.job j
    ) c
    where c.n < 6

    union all

    select jsonb_build_object(
             'chave', 'trava',
             'texto', 'TRAVA LIGADA: configuracoes.trava_emergencia esta ativa. Nada publica enquanto isso. Se foi de proposito, ignore; se foi esquecimento, soltar com soltar_trava().'
           )
    from public.configuracoes c
    where c.id = 1 and c.trava_emergencia

    union all

    select jsonb_build_object(
             'chave', 'coleta_desligada',
             'texto', 'COLETA DESLIGADA: configuracoes.coleta_ativa esta falsa. O motor nao capta nada.'
           )
    from public.configuracoes c
    where c.id = 1 and not c.coleta_ativa

    union all

    select jsonb_build_object(
             'chave', 'token_ml_vencido',
             'texto', format('TOKEN VENCIDO MENTINDO: credenciais_ml diz "%s" mas expira_em passou em %s. A situacao nao reflete a validade.',
                             m.situacao, to_char(m.expira_em, 'DD/MM HH24:MI'))
           )
    from public.credenciais_ml m
    where m.id = 1 and m.expira_em < now() and m.situacao = 'pronta'
  ) x;
$function$;

revoke all on function public.motor_travado() from public, anon;
grant execute on function public.motor_travado() to service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 4. O disco ganha um limite de verdade.
-- ---------------------------------------------------------------------------
alter table public.configuracoes
  add column if not exists disco_limite_bytes bigint
    not null default (8::bigint * 1024 * 1024 * 1024);

comment on column public.configuracoes.disco_limite_bytes is
  'Tamanho provisionado do disco, em bytes. Valor inicial 8 GB = disco minimo de projeto Supabase pago, usado como piso seguro porque o banco ja passou dos 500 MB do plano gratuito. Corrigir com o tamanho real (Project Settings, Compute and Disk, Disk size) para a conta ficar exata.';

create or replace function public.saude_do_disco()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_bytes bigint;
  v_limite bigint;
  v_somente_leitura boolean;
  v_uso numeric;
begin
  select pg_database_size(current_database()) into v_bytes;
  select current_setting('default_transaction_read_only') = 'on' into v_somente_leitura;
  select c.disco_limite_bytes into v_limite from public.configuracoes c where c.id = 1;

  v_limite := greatest(coalesce(v_limite, 8::bigint * 1024 * 1024 * 1024), 1);
  v_uso := round(v_bytes::numeric / v_limite, 4);

  return jsonb_build_object(
    'tamanho', pg_size_pretty(v_bytes),
    'bytes', v_bytes,
    'limite', pg_size_pretty(v_limite),
    'limite_bytes', v_limite,
    'uso_fracao', v_uso,
    'somente_leitura', v_somente_leitura,
    -- 'travado' e a emergencia real: banco em somente-leitura nao grava nada e
    -- o motor inteiro morre calado. 85% e onde se age com folga; 95% ja doi.
    'veredito', case
      when v_somente_leitura then 'travado'
      when v_uso >= 0.95 then 'critico'
      when v_uso >= 0.85 then 'perto_do_limite'
      else 'ok'
    end,
    'maiores', (
      select coalesce(jsonb_agg(jsonb_build_object('tabela', t.tabela, 'tamanho', t.tamanho)
                                order by t.bytes desc), '[]'::jsonb)
      from (
        select c.relname as tabela,
               pg_size_pretty(pg_total_relation_size(c.oid)) as tamanho,
               pg_total_relation_size(c.oid) as bytes
        from pg_class c
        join pg_namespace ns on ns.oid = c.relnamespace
        where ns.nspname in ('public', 'cron')
          and c.relkind = 'r'
        order by pg_total_relation_size(c.oid) desc
        limit 5
      ) t
    )
  );
end;
$function$;

revoke all on function public.saude_do_disco() from public, anon;
grant execute on function public.saude_do_disco() to service_role, authenticated;

create or replace function public.disco_em_risco()
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select case
    when d.veredito in ('travado', 'critico', 'perto_do_limite')
      then jsonb_build_array(jsonb_build_object(
             'chave', 'disco',
             'texto', format('DISCO %s: %s de %s usados (%s%%). %s',
               upper(d.veredito), d.tamanho, d.limite, round(d.uso * 100),
               case when d.veredito = 'travado'
                    then 'O banco esta em SOMENTE LEITURA: nada grava, o motor inteiro morre calado.'
                    else 'Disco cheio para a gravacao e o motor para sem aviso. A retencao limpa historico_precos e auditoria.' end)))
    else '[]'::jsonb
  end
  -- UMA chamada so: saude_do_disco() varre o tamanho de cinco tabelas, e
  -- chamar de novo por campo sairia caro numa funcao que roda a cada 30 min.
  from (
    select q.s ->> 'veredito' as veredito,
           q.s ->> 'tamanho'  as tamanho,
           q.s ->> 'limite'   as limite,
           (q.s ->> 'uso_fracao')::numeric as uso
    from (select public.saude_do_disco() as s) q
  ) d;
$function$;

revoke all on function public.disco_em_risco() from public, anon;
grant execute on function public.disco_em_risco() to service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Histerese na regra de degradacao, para ela nao piscar.
-- ---------------------------------------------------------------------------
-- Dispara abaixo de 0,60; so se cala acima de 0,75. Na faixa do meio o alerta
-- FICA ABERTO se ja estava, em vez de mandar NORMALIZADO e disparar de novo
-- meia hora depois. Fonte 'cega' fica de fora: ela tem alarme proprio, e um
-- problema so merece um aviso.
create or replace function public.fontes_degradadas()
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'chave', 'degradada:' || d.slug,
           'texto', format(
             'LEITURA CAINDO: a fonte %s leu %s itens na ultima hora, %s%% do normal (base %s, origem %s). Erros da ultima hora: %s. Menos leitura e menos chance de pegar queda de preco. Se cala acima de 75%%.',
             d.slug,
             d.vistos_1h,
             round(d.razao * 100),
             d.base,
             d.origem,
             coalesce(d.codigos::text, 'nenhum registrado'))
         )), '[]'::jsonb)
  from (
    select key as slug,
           (value ->> 'vistos_1h')::numeric as vistos_1h,
           (value ->> 'vistos_base')::numeric as base,
           (value ->> 'base_origem') as origem,
           (value ->> 'leitura_vs_base')::numeric as razao,
           value -> 'codigos_de_falha_1h' as codigos,
           exists (select 1 from public.alertas_enviados a
                    where a.chave = 'degradada:' || key) as ja_aberto
    from jsonb_each(public.saude_da_coleta() -> 'por_fonte')
    where (value ->> 'leitura_vs_base') is not null
      and (value ->> 'veredito') <> 'cega'
  ) d
  where d.base >= 100
    and (d.razao < 0.60 or (d.ja_aberto and d.razao < 0.75));
$function$;

revoke all on function public.fontes_degradadas() from public, anon;
grant execute on function public.fontes_degradadas() to service_role, authenticated;
