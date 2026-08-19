-- Onde o Baixou publica. Os coletores leem daqui para enfileirar, e o worker
-- so aceita despachar para este par canal/destino.
alter table public.configuracoes
  add column canal_padrao text not null default 'telegram'
    constraint configuracoes_canal_ck check (canal_padrao in ('telegram', 'whatsapp', 'email', 'site')),
  add column destino_padrao text not null default ''
    constraint configuracoes_destino_ck check (
      destino_padrao = '' or char_length(destino_padrao) between 2 and 160
    );

comment on column public.configuracoes.destino_padrao is
  'Canal de publicacao. Vazio significa nao configurado: o worker recusa despachar.';

update public.configuracoes
  set canal_padrao = 'telegram', destino_padrao = '@baixouofertas'
  where id = 1;
