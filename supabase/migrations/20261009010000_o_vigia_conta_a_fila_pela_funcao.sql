-- O vigia_do_motor() roda dentro do banco a cada 2h, sem ninguem olhando, e
-- contava a fila A MAO: `situacao not in ('publicada','descartada')`. Faltava
-- 'cancelada'. Medido em 06/10: o vigia dizia fila_pendente 7 enquanto
-- public.fila_pendente() dizia 0.
--
-- O numero errado nao era o pior. A regra de cegueira escrita no proprio
-- prompt do vigia — "publicou_24h = 0 E fila_pendente = 0 por DOIS check-ins
-- seguidos" — ficava IMPOSSIVEL de disparar, porque fila_pendente estava
-- travado em 7 para sempre. Guarda que nao pode disparar e pior que guarda que
-- fala demais: o motor podia parar e o alarme ficaria calado.
--
-- Em 05/10 (4d5281e) esta conta foi corrigida nos dois textos agendados e na
-- funcao fila_pendente(), e ficou errada justamente aqui dentro. Por isso a
-- correcao agora e CHAMAR a funcao, nao reescrever a condicao: regra que vive
-- em varios lugares erra diferente em cada um.
--
-- Reescrita por leitura-modificacao-gravacao (pg_get_functiondef + replace),
-- porque o corpo do vigia nao esta neste repositorio em forma canonica. As
-- guardas levantam excecao se a ancora nao existir ou se a troca nao pegar —
-- migracao que falha em silencio seria o mesmo defeito de novo.
do $mig$
declare
  v_def   text;
  v_novo  text;
  v_ancora text := '  select count(*) into v_fila
  from public.fila_publicacao f where f.situacao not in (''publicada'', ''descartada'');';
  v_troca  text := '  -- Conta pela funcao, nunca a mao: public.fila_pendente() sabe quais estados
  -- sao terminais (publicada, descartada e TAMBEM cancelada). Aqui a conta era
  -- a mao e esquecia cancelada, entao reportava 7 com a fila realmente vazia,
  -- e a regra de cegueira deste proprio vigia nunca podia disparar.
  select public.fila_pendente() into v_fila;';
begin
  v_def := pg_get_functiondef('public.vigia_do_motor(int)'::regprocedure);

  if position(v_ancora in v_def) = 0 then
    raise exception 'ancora nao encontrada em vigia_do_motor(int): a conta a mao mudou de forma. Reler a definicao antes de reescrever.';
  end if;

  v_novo := replace(v_def, v_ancora, v_troca);

  if v_novo = v_def then
    raise exception 'replace() nao teve efeito em vigia_do_motor(int)';
  end if;

  execute v_novo;

  -- Confere no banco que a reescrita pegou de verdade.
  v_def := pg_get_functiondef('public.vigia_do_motor(int)'::regprocedure);

  if position('public.fila_pendente() into v_fila' in v_def) = 0 then
    raise exception 'vigia_do_motor(int) nao ficou com a chamada de public.fila_pendente()';
  end if;

  if position('from public.fila_publicacao f where f.situacao not in' in v_def) > 0 then
    raise exception 'a conta a mao ainda esta dentro de vigia_do_motor(int)';
  end if;
end
$mig$;
