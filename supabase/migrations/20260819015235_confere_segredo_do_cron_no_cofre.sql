-- Uma fonte da verdade so para o segredo do cron: o cofre.
--
-- Antes, o mesmo valor precisava existir identico no cofre e nos secrets da
-- Edge Function, e mante-los em sincronia na mao e uma armadilha: qualquer
-- espaco sobrando ou troca em um dos lados derruba tudo com um 401 mudo.
-- Agora a funcao pergunta ao banco, e o banco e quem sabe.
create function public.cron_secreto_confere(p_segredo text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_esperado text;
begin
  if p_segredo is null or length(p_segredo) < 16 then
    return false;
  end if;

  select decrypted_secret into v_esperado
  from vault.decrypted_secrets
  where name = 'baixou_worker_cron_secret';

  if v_esperado is null then
    return false;
  end if;

  -- Compara os digestos: nao revela o tamanho nem o conteudo do esperado,
  -- e tolera espaco ou quebra de linha nas pontas, que so aparecem por
  -- acidente de copiar e colar.
  return encode(sha256(convert_to(btrim(p_segredo), 'UTF8')), 'hex')
       = encode(sha256(convert_to(btrim(v_esperado), 'UTF8')), 'hex');
end;
$$;

revoke execute on function public.cron_secreto_confere(text) from anon, authenticated, public;
grant execute on function public.cron_secreto_confere(text) to service_role;

comment on function public.cron_secreto_confere(text) is
  'Confere o segredo do cron contra o cofre. Unica fonte da verdade.';
