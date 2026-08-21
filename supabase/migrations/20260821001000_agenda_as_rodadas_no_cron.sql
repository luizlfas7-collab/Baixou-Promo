-- O cron nunca foi agendado. Ate aqui todas as rodadas foram disparadas a mao,
-- e por isso o motor "existia" sem nunca andar sozinho.
--
--   coletor  a cada 5 min  - so observa preco. E o que forma o historico, e
--                            sem historico nao existe desconto verificado.
--   worker   a cada 2 min  - publica no maximo um item, e ainda assim so
--                            quando as porteiras deixam.
--   faxina   a cada 10 min - solta reserva vencida e cancela aprovacao morta.
--
-- Nenhum deles fura a trava de emergencia.
create function public.rodar_faxina()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservas integer;
  v_aprovacoes integer;
begin
  select public.liberar_reservas_vencidas() into v_reservas;
  select public.cancelar_aprovacoes_vencidas() into v_aprovacoes;

  return jsonb_build_object(
    'reservas_liberadas', v_reservas,
    'aprovacoes_canceladas', v_aprovacoes
  );
end;
$$;

revoke execute on function public.rodar_faxina() from anon, authenticated, public;

comment on function public.rodar_faxina() is
  'Manutencao periodica: solta reserva vencida e cancela aprovacao que deixou de valer.';

select cron.schedule('baixou-coletor-ml', '*/5 * * * *', $$select public.disparar_coletor_ml()$$);
select cron.schedule('baixou-worker',     '*/2 * * * *', $$select public.disparar_worker()$$);
select cron.schedule('baixou-faxina',    '*/10 * * * *', $$select public.rodar_faxina()$$);
