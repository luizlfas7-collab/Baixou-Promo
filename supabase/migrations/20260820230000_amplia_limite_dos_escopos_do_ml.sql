-- O Mercado Livre devolve a lista de escopos concedidos com um item por
-- unidade de negocio (urn:ml:mktp:..., urn:global:admin:...). Na pratica isso
-- passa de 600 caracteres, e o limite de 200 que eu tinha posto era chute meu,
-- nao medida real: a conexao completava e morria ao gravar o metadado.
alter table public.credenciais_ml
  drop constraint credenciais_ml_escopos_ck;

alter table public.credenciais_ml
  add constraint credenciais_ml_escopos_ck
    check (escopos is null or char_length(escopos) <= 4000);
