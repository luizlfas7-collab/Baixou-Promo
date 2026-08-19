-- O proprio banco chama as Edge Functions por HTTP, no ritmo do cron.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- Guarda a URL do projeto em vez de embutir no corpo do job: restaurar em
-- outro projeto so precisa trocar esta linha, e nao caça-la dentro do cron.
-- (No motor de referencia a URL ficava fixa no job, e um banco restaurado
-- chamava as funcoes do projeto antigo, em silencio.)
alter table public.configuracoes
  add column url_das_funcoes text not null default ''
    constraint configuracoes_url_funcoes_ck check (
      url_das_funcoes = '' or url_das_funcoes ~ '^https://[a-z0-9]{20}\.supabase\.co/functions/v1$'
    );

comment on column public.configuracoes.url_das_funcoes is
  'Base das Edge Functions deste projeto. Vazio impede o agendamento de chamar qualquer coisa.';
