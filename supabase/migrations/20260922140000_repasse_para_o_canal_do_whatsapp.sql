-- Repasse assistido para o canal do WhatsApp.
--
-- Por que assistido e nao automatico: a Meta nao expoe Canais no Cloud API.
-- Nao existe endpoint oficial para publicar em canal, e as bibliotecas que
-- fazem isso falam o protocolo do WhatsApp Web por engenharia reversa —
-- funcionam ate o numero ser banido, sem aviso e sem recurso, levando junto a
-- audiencia. O caminho oficial (mensagem de marketing 1:1) sairia por ~R$ 0,35
-- por mensagem entregue: com 7 posts por dia, R$ 73,50 por mes POR INSCRITO.
-- Nenhum dos dois presta. Entao o motor monta o post e a pessoa cola.
--
-- Guardar o destino aqui, e nao em variavel de ambiente, e proposital: liga e
-- desliga sem redeploy, e nulo significa desligado. Ate alguem preencher, o
-- worker se comporta exatamente como antes.

alter table public.configuracoes
  add column if not exists repasse_whatsapp_chat_id text;

comment on column public.configuracoes.repasse_whatsapp_chat_id is
  'Conversa privada do Telegram que recebe o post ja formatado para colar no '
  'canal do WhatsApp. Nulo desliga o repasse. Aceita id numerico (inclusive '
  'negativo, para grupo) ou @usuario.';

-- Formato conferido no banco para que erro de digitacao apareca na hora de
-- salvar, e nao seis horas depois como uma sequencia de repasses falhados.
alter table public.configuracoes
  drop constraint if exists configuracoes_repasse_whatsapp_chat_id_formato;

alter table public.configuracoes
  add constraint configuracoes_repasse_whatsapp_chat_id_formato
  check (
    repasse_whatsapp_chat_id is null
    or repasse_whatsapp_chat_id ~ '^-?[0-9]{1,20}$'
    or repasse_whatsapp_chat_id ~ '^@[A-Za-z][A-Za-z0-9_]{4,31}$'
  );

do $$
declare
  v_colunas int;
begin
  select count(*) into v_colunas
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'configuracoes'
    and column_name = 'repasse_whatsapp_chat_id';

  if v_colunas <> 1 then
    raise exception 'repasse_whatsapp_chat_id nao foi criada';
  end if;

  -- Ligar o repasse nao pode ser efeito colateral da migracao: quem liga e o
  -- dono, sabendo qual conversa vai receber.
  if exists (
    select 1 from public.configuracoes
    where id = 1 and repasse_whatsapp_chat_id is not null
  ) then
    raise exception 'a migracao nao deveria ter ligado o repasse sozinha';
  end if;
end $$;
