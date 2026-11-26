-- O alarme saiu para o dono com "Erros da ultima hora: null".
--
-- `codigos_de_falha_1h` vem como null de JSON quando o coletor publicado ainda
-- nao grava os codigos. jsonb null convertido para text da a STRING 'null', e
-- por isso o coalesce nao pegava: ele so troca nulo de SQL. nullif resolve.
--
-- Nao e cosmetico. O alarme e lido as 3 da manha por uma pessoa decidindo se
-- levanta da cama; texto com "null" dentro ensina o leitor a desconfiar da
-- mensagem inteira, e alarme em que nao se confia e alarme que nao existe.
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
             coalesce(nullif(d.codigos::text, 'null'), 'nenhum codigo registrado'))
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
