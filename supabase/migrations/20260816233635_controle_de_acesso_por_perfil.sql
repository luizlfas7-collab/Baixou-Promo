-- Cadastro aberto nao pode virar acesso ao painel: quem se cadastra nasce
-- inativo e so enxerga os dados operacionais depois de liberado.
alter table public.perfis
  add column ativo boolean not null default false;

comment on column public.perfis.ativo is
  'Libera o acesso aos dados operacionais. Nasce falso de proposito.';

-- Usada nas politicas das tabelas do motor. Roda com os direitos de quem
-- chama: a propria politica de perfis ja permite ler a linha do usuario.
create function public.eh_operador_ativo()
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from public.perfis p
    where p.id = (select auth.uid())
      and p.ativo
  );
$$;

revoke execute on function public.eh_operador_ativo() from anon, public;
grant execute on function public.eh_operador_ativo() to authenticated;

-- O papel decide o que a pessoa pode fazer; nunca deve ser editavel por ela.
create function public.perfil_protege_campos_sensiveis()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.papel is distinct from old.papel
     or new.ativo is distinct from old.ativo
     or new.criado_em is distinct from old.criado_em then
    raise exception 'Identidade, papel e liberacao de acesso nao podem ser alterados pelo proprio usuario'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke execute on function public.perfil_protege_campos_sensiveis() from anon, authenticated, public;

create trigger ao_atualizar_perfil_protege
  before update on public.perfis
  for each row
  when (current_setting('role', true) is distinct from 'service_role')
  execute function public.perfil_protege_campos_sensiveis();
