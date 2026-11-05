-- Dois defeitos achados em 05/10, um deles no MEU proprio relatorio.
--
-- 1) `fila_pendente` mentia. A conta usada no boletim e no vigia filtrava
--    `situacao not in ('publicada','descartada')` e por isso contava as linhas
--    'cancelada' como se fossem itens esperando a vez. Deu 7 pendentes com a
--    fila REALMENTE vazia. E a repeticao exata do erro de 28/09, que era a
--    mesma conta sem filtro nenhum: a tabela e LIVRO-CAIXA, estado terminal
--    fica gravado para sempre, e conta que nao exclui todos eles so cresce.
--
--    O conserto nao e corrigir a consulta nos dois prompts agendados: e tirar a
--    definicao de dentro deles. Enquanto a regra vive no texto de quem
--    pergunta, cada lugar pode errar de um jeito diferente. Aqui ela vive uma
--    vez, no banco.
--
-- 2) 7 ofertas APROVADAS morreram sem ir ao ar, e nada avisou. Todas com
--    ultimo_erro_codigo = 'aprovacao_vencida'.
--
--    A conta de por que: aprovacao_idade_maxima_segundos = 3600 (a aprovacao
--    vale 1 hora) e intervalo_minimo_segundos = 600 com
--    max_publicacoes_por_hora = 6 (um post a cada 10 minutos). Logo a fila
--    escoa no maximo ~6 por hora, e aprovacao que passa de 1 hora vence.
--    Rajada maior que 6 numa hora perde o excedente.
--
--    Isso NAO e erro de configuracao e nao se mexe aqui: o teto de 1 hora
--    existe para o canal nunca publicar preco velho, e o espacamento de 10
--    minutos existe para nao inundar o canal. As duas regras estao certas. O
--    que esta errado e perder oferta EM SILENCIO.
--
--    Medido: 5 perdidas em 01/10 (a rajada logo depois do conserto da cobertura
--    do ML) e 2 em 03/10, contra 220 publicadas. O piso do alarme fica em 3
--    para pegar a rajada de 01/10 e ficar calado nas 2 de 03/10 — perder uma ou
--    duas no pico e o custo normal de um teto que protege o preco.

create or replace function public.fila_pendente()
returns bigint language sql stable security definer set search_path to ''
as $function$
  -- Estados TERMINAIS, nomeados um por um e de proposito. Se um estado novo
  -- aparecer em fila_publicacao, ele conta como pendente e aparece alto no
  -- boletim — o que e o comportamento certo: estado que ninguem classificou
  -- deve chamar atencao, nao desaparecer na conta.
  select count(*) from public.fila_publicacao
   where situacao not in ('publicada', 'descartada', 'cancelada')
$function$;

comment on function public.fila_pendente() is
  'Quantos itens REALMENTE esperam publicacao. fila_publicacao e livro-caixa: '
  'publicada, descartada e cancelada sao terminais e ficam gravados. Normal = 0.';

revoke all on function public.fila_pendente() from public, anon;
grant execute on function public.fila_pendente() to authenticated, service_role;

create or replace function public.aprovacoes_vencidas(p_horas int default 24)
returns jsonb language sql stable security definer set search_path to ''
as $function$
  with perdidas as (
    select f.id, o.titulo, f.prioridade, fo.slug as fonte
      from public.fila_publicacao f
      join public.ofertas o  on o.id = f.oferta_id
      join public.fontes fo  on fo.id = o.fonte_id
     where f.situacao = 'cancelada'
       and f.ultimo_erro_codigo = 'aprovacao_vencida'
       and f.atualizado_em > now() - make_interval(hours => p_horas)
  )
  select case when (select count(*) from perdidas) >= 3 then
    jsonb_build_array(jsonb_build_object(
      'chave', 'aprovacao_vencida',
      'texto', format(
        'OFERTA APROVADA PERDIDA: %s itens passaram da barra e venceram antes de publicar nas ultimas %sh (%s). '
        'A aprovacao vale 1h e a fila escoa 1 post a cada 10min (teto 6/h), entao rajada maior que isso perde o excedente. '
        'Nao e erro de configuracao: o teto protege o canal de preco velho. E volume de rajada.',
        (select count(*) from perdidas), p_horas,
        (select string_agg(format('%s nota %s', fonte, prioridade), '; ') from perdidas))
    ))
  else '[]'::jsonb end
$function$;

comment on function public.aprovacoes_vencidas(int) is
  'Alarma quando oferta aprovada morre antes de publicar. Piso 3 em 24h: '
  'perder 1 ou 2 no pico e o custo normal do teto de 1h da aprovacao.';

revoke all on function public.aprovacoes_vencidas(int) from public, anon;
grant execute on function public.aprovacoes_vencidas(int) to authenticated, service_role;

-- Pendura no vigia que ja roda dentro do banco, do mesmo jeito que
-- entrega_por_fonte() foi pendurada em 03/10: le a definicao viva, insere a
-- linha antes da ancora, e ABORTA se a ancora nao estiver la ou se a reescrita
-- nao tiver pegado. Alarme que o conserto nao instalou de verdade e pior que
-- alarme que nao existe.
do $migracao$
declare
  v_fonte text;
  v_novo  text;
  v_ancora text := '  select coalesce(array_agg(x->>''chave''), ''{}'') into v_abertos';
  v_linha  text := '  v_problemas := v_problemas || public.aprovacoes_vencidas(24);' || E'\n';
begin
  v_fonte := pg_get_functiondef('public.vigia_do_motor(int)'::regprocedure);

  if position(v_ancora in v_fonte) = 0 then
    raise exception 'Ancora nao encontrada em vigia_do_motor: a funcao mudou, revisar a mao';
  end if;

  if position('aprovacoes_vencidas' in v_fonte) > 0 then
    raise notice 'vigia_do_motor ja chama aprovacoes_vencidas, nada a fazer';
    return;
  end if;

  v_novo := replace(v_fonte, v_ancora, v_linha || v_ancora);

  if v_novo = v_fonte then
    raise exception 'A reescrita de vigia_do_motor nao pegou';
  end if;

  execute v_novo;

  if position('aprovacoes_vencidas' in
      pg_get_functiondef('public.vigia_do_motor(int)'::regprocedure)) = 0 then
    raise exception 'vigia_do_motor foi reescrita mas nao ficou com a chamada nova';
  end if;
end
$migracao$;
