-- Mais produtos vigiados, porque o funil nao aperta no criterio
--
-- Medicao de 195 itens lidos: 112 estao no preco normal, 26 acima, 3 perto do
-- corte e apenas 2 passam. O criterio nao esta rigido demais — a realidade e
-- que pouquissima coisa esta em promocao de verdade a qualquer momento.
--
-- Logo, baixar o corte nao enche o canal: enche de produto em preco normal
-- anunciado como oferta, que e pior que canal parado. O que enche e vigiar
-- mais produto.
--
-- Vigiar mais exige mais leitura por hora, senao a revisita estica e queda
-- relampago passa batido. As duas coisas sobem juntas, sempre.
--
--   antes:  200 produtos · 120 leituras/h · revisita 1h40
--   agora:  500 produtos · 300 leituras/h · revisita 1h40
--
-- A carga no ML sai de ~480 para ~1200 chamadas por hora (cada produto custa
-- ~4). Fica em 20 por minuto — longe de incomodar.
--
-- O cron do coletor foi de */5 para */2 e o da descoberta de hora em hora para
-- */20, aplicados com cron.alter_job nos jobs 1 e 4.

create or replace function public.watchlist_teto()
returns integer
language sql
immutable
set search_path to ''
as $$ select 500 $$;

comment on function public.watchlist_teto() is
  'Maximo de itens habilitados. Amarrado a vazao: 300 leituras/hora dao revisita de ~1h40 em 500 itens. Subir isto sem subir a frequencia do cron estica a revisita.';

create or replace function public.rodar_descoberta()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_colheita jsonb;
  v_pedidos integer;
begin
  v_colheita := public.descoberta_coletar(40);
  v_pedidos := public.descoberta_disparar(8);

  delete from public.descobertas_pendentes
  where processada_em is not null and processada_em < now() - interval '7 days';

  return v_colheita || jsonb_build_object('paginas_pedidas', v_pedidos);
end;
$$;
