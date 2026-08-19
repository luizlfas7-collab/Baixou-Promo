-- Perfil do usuario, espelhando auth.users.
create table public.perfis (
  id uuid primary key references auth.users (id) on delete cascade,
  nome text,
  email text,
  papel text not null default 'operador' check (papel in ('admin', 'operador')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

alter table public.perfis enable row level security;

create policy "perfil proprio: leitura"
  on public.perfis for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "perfil proprio: atualizacao"
  on public.perfis for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- Cria o perfil automaticamente quando um usuario se cadastra.
create function public.trata_novo_usuario()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.perfis (id, nome, email)
  values (
    new.id,
    nullif(new.raw_user_meta_data ->> 'nome', ''),
    new.email
  );
  return new;
end;
$$;

create trigger ao_criar_usuario
  after insert on auth.users
  for each row execute function public.trata_novo_usuario();

-- Mantem atualizado_em em dia.
create function public.toca_atualizado_em()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.atualizado_em = now();
  return new;
end;
$$;

create trigger ao_atualizar_perfil
  before update on public.perfis
  for each row execute function public.toca_atualizado_em();
