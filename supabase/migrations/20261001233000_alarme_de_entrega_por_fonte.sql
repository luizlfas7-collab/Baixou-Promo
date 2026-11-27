-- Alarme de ENTREGA, por fonte.
--
-- O BURACO QUE ISTO FECHA: o vigia tinha a condicao 'sem_publicacao', mas ela
-- so dispara com `v_publicou = 0 and v_fila = 0` — ou seja, quando o motor
-- INTEIRO para. Em 01/10 a Shopee publicou 4 e o Mercado Livre publicou zero
-- pelo terceiro dia seguido: v_publicou era 4, e o alarme ficou calado.
--
-- Pior: saude_da_coleta() dizia 'saudavel' nas duas fontes, e dizia a verdade.
-- Ela mede se o motor LE, nao se ele ENTREGA. Uma fonte pode ler 300 itens por
-- hora, com veredito saudavel, e nao soltar um post por tres dias.
--
-- Esta funcao olha a unica coisa que importa para o dono: saiu post ou nao
-- saiu, fonte por fonte.
--
-- A REGRA E DELIBERADAMENTE GROSSA: zero em 24h, numa fonte que vinha fazendo
-- pelo menos 1 por dia na semana anterior. Nao e queda percentual. Cair de 6
-- para 2 pode ser um dia sem promocao no varejo, e alarme que dispara por isso
-- e alarme que se aprende a ignorar. Zero com historico de entrega e fato.
--
-- MEDIDO em 01/10, antes de armar: ML 3,9 posts/dia na semana (alarmaria se
-- zerasse), Shopee 0,57/dia (nao alarma, nunca teve constancia para isso).
-- Nenhum falso positivo hoje, e teria gritado nos tres dias que o ML passou
-- em zero.
create or replace function public.entrega_por_fonte()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  with contagem as (
    select f.slug,
           count(p.id) filter (where p.publicado_em > now() - interval '24 hours') as recentes,
           count(p.id) filter (where p.publicado_em <= now() - interval '24 hours'
                                 and p.publicado_em >  now() - interval '8 days') as anteriores
      from public.fontes f
      left join public.ofertas o     on o.fonte_id = f.id
      left join public.publicacoes p on p.oferta_id = o.id
                                    and p.situacao = 'publicada'
     where f.habilitada
     group by f.slug
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'chave', 'entrega:' || slug,
           'texto', format(
             'FONTE MUDA: %s nao publicou nada em 24h, mas vinha entregando %s por dia nos 7 dias anteriores (%s posts no total). Le e nao entrega — o alarme geral fica calado porque as OUTRAS fontes publicam.',
             slug, round(anteriores / 7.0, 1), anteriores)
         )), '[]'::jsonb)
    from contagem
   where recentes = 0 and anteriores >= 7
$function$;

revoke all on function public.entrega_por_fonte() from public, anon, authenticated;

-- Pendura no vigia que ja roda de meia em meia hora (job baixou-vigia).
--
-- Leitura-modificacao-reescrita em vez de recolar a funcao inteira: a
-- vigia_do_motor tem 200 linhas e transcrever a mao e como se introduz defeito
-- em codigo que funciona. Se a ancora nao existir, isto levanta excecao em vez
-- de gravar uma funcao pela metade.
do $migracao$
declare
  v_fonte_sql text;
  v_ancora    text := '  select coalesce(array_agg(x->>''chave''), ''{}'') into v_abertos';
  v_novo      text := '  -- Fonte que LE e nao ENTREGA. Ver entrega_por_fonte().' || e'\n' ||
                      '  v_problemas := v_problemas || public.entrega_por_fonte();' || e'\n\n';
begin
  v_fonte_sql := pg_get_functiondef('public.vigia_do_motor(integer)'::regprocedure);

  if position('public.entrega_por_fonte()' in v_fonte_sql) > 0 then
    raise notice 'vigia_do_motor ja chama entrega_por_fonte; nada a fazer';
    return;
  end if;

  if position(v_ancora in v_fonte_sql) = 0 then
    raise exception 'Ancora nao encontrada em vigia_do_motor. Nada foi alterado.';
  end if;

  v_fonte_sql := replace(v_fonte_sql, v_ancora, v_novo || v_ancora);

  if position('public.entrega_por_fonte()' in v_fonte_sql) = 0 then
    raise exception 'A reescrita nao inseriu a chamada. Nada foi alterado.';
  end if;

  execute v_fonte_sql;
end
$migracao$;
