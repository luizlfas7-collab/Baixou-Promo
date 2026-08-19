-- O canal definitivo do Baixou. O valor anterior (@baixouofertas) nunca
-- existiu no Telegram: o canal fora criado como privado, e canal privado nao
-- tem @nome. O bot respondia "chat not found" e o motor, corretamente, se
-- recusava a publicar.
update public.configuracoes
  set destino_padrao = '@aixou_promocoes'
  where id = 1;
