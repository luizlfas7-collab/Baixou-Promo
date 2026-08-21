-- Soltar a trava com um UPDATE cru e facil, e por isso mesmo perigoso: nao
-- confere nada. Estas duas funcoes existem para que soltar exija passar por
-- uma vistoria, e puxar seja sempre imediato.

/** Vistoria antes de liberar. Nao altera nada; serve para olhar. */
create function public.vistoria_para_soltar()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'ml_conectado', exists (select 1 from vault.secrets where name = 'baixou_ml_refresh_token'),
    'telegram_configurado', (select destino_padrao <> '' from public.configuracoes where id = 1),
    'coleta_ativa', (select coleta_ativa from public.configuracoes where id = 1),
    'fonte_ml_ligada', (select habilitada from public.fontes where slug = 'mercado_livre_api_oficial'),
    'itens_na_watchlist', (select count(*) from public.itens_ml where habilitado and produto_catalogo is not null),
    'itens_com_historico_suficiente', (
      select count(*) from (
        select h.oferta_id from public.historico_precos h
        group by h.oferta_id having count(distinct h.preco) >= 2
      ) s
    ),
    'cron_agendado', (select count(*) from cron.job where active),
    'destino_em_quarentena', exists (select 1 from public.estado_destino where quarentena_em is not null),
    'trava_ligada', (select trava_emergencia from public.configuracoes where id = 1)
  );
$$;

revoke execute on function public.vistoria_para_soltar() from anon, public;
grant execute on function public.vistoria_para_soltar() to authenticated, service_role;

/**
 * Solta a trava. Recusa enquanto faltar peca essencial.
 *
 * O historico de preco NAO e exigido: sem ele nada e aprovado de qualquer
 * forma, entao soltar cedo nao publica nada errado, so deixa o motor pronto.
 */
create function public.soltar_trava()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v jsonb;
  v_impedimentos text[] := '{}';
begin
  select public.vistoria_para_soltar() into v;

  if not (v ->> 'ml_conectado')::boolean then
    v_impedimentos := v_impedimentos || 'Mercado Livre nao conectado';
  end if;

  if not (v ->> 'telegram_configurado')::boolean then
    v_impedimentos := v_impedimentos || 'Canal do Telegram nao configurado';
  end if;

  if (v ->> 'destino_em_quarentena')::boolean then
    v_impedimentos := v_impedimentos || 'Destino em quarentena: rode reconciliar_destino antes';
  end if;

  if (v ->> 'itens_na_watchlist')::int = 0 then
    v_impedimentos := v_impedimentos || 'Watchlist vazia';
  end if;

  if array_length(v_impedimentos, 1) is not null then
    return jsonb_build_object('soltou', false, 'impedimentos', to_jsonb(v_impedimentos), 'vistoria', v);
  end if;

  update public.configuracoes set trava_emergencia = false where id = 1;

  return jsonb_build_object('soltou', true, 'vistoria', public.vistoria_para_soltar());
end;
$$;

revoke execute on function public.soltar_trava() from anon, public;
grant execute on function public.soltar_trava() to authenticated, service_role;

/** Freio de mao. Sem conferencia nenhuma: parar tem que ser sempre possivel. */
create function public.puxar_trava()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.configuracoes set trava_emergencia = true where id = 1;
  return jsonb_build_object('trava_ligada', true, 'em', now());
end;
$$;

revoke execute on function public.puxar_trava() from anon, public;
grant execute on function public.puxar_trava() to authenticated, service_role;
