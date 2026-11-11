# Baixou Social Agent — diagnóstico Instagram

## Escopo

Projeto Supabase `xxskmxhpzbqzxoaffiul`, branch `feature/instagram-social-agent`.
A tabela `public.instagram_publicacoes` já existe. Este diagnóstico não a lê
nem a modifica. Não altera o worker Telegram, cron, fila ou publicação.

## Função separada

`baixou-instagram-auth-test` aceita somente GET, sem parâmetros, em:

`https://xxskmxhpzbqzxoaffiul.supabase.co/functions/v1/baixou-instagram-auth-test`

Faz exclusivamente consultas de leitura:

- `GET https://graph.instagram.com/me?fields=id,username,account_type`
- `GET https://graph.instagram.com/me/permissions` como introspecção opcional.
  Se indisponível, a resposta diz `unavailable`/`unverified`, sem inferir escopos.

O token vem apenas de `INSTAGRAM_ACCESS_TOKEN` em Edge Function Secrets. É enviado
para Instagram em Authorization, nunca na URL. Não é aceito token por query/body.
Respostas são limitadas aos campos permitidos; erros brutos e exceções não são
registrados nem retornados. Timeout, bloqueio de redirects e `Cache-Control:
no-store` estão habilitados. Não há chamadas a `/media` ou `/media_publish`.

## Autenticação administrativa

`verify_jwt = true` permanece habilitado. Além da verificação do gateway, a função
exige a chave `service_role` do projeto; chave anon e sessão comum não bastam.
Não usa `user_metadata` ou decodificação de claims para autorização.

Em chamadas diretas de backend, usar `Authorization: Bearer <service_role>`.
No teste do Dashboard, onde o proxy pode substituir Authorization, usar o header
`X-Baixou-Admin-Key: <service_role>` e manter a verificação JWT habilitada.
Não copiar credenciais para documentação, navegador público, logs ou frontend.
Limpar o campo do painel após testar.

A comparação com `SUPABASE_SERVICE_ROLE_KEY` é feita por digest. Se a chave
administrativa válida do Dashboard diferir da chave injetada, a função valida a
credencial no endpoint administrativo do próprio Supabase Auth
`GET /auth/v1/admin/users?page=1&per_page=1`. Somente HTTP 200 autoriza; o corpo é
descartado sem leitura, persistência ou retorno de dados de usuários. Falhas de
autenticação/rede fecham o acesso. Este fallback não desativa o gateway JWT.

## Permissões e limites

Instagram Login usa `instagram_business_basic` para a consulta de perfil. Uma
leitura bem-sucedida demonstra acesso efetivo ao perfil, mas não certifica todos
os escopos, prazo de expiração, App Review ou acesso a outras contas.
`instagram_business_content_publish` é uma permissão separada. Só é marcada
`granted` quando a introspecção devolve explicitamente esse escopo concedido.
Mesmo nesse caso, publicação não é testada por esta função.

## Resultado verificado em 14/10/2026

- Função ativa, versão 3, `verify_jwt: true`.
- Sem Authorization: HTTP 401 no gateway.
- Chamada administrativa pelo Dashboard: HTTP 200.
- Conta: `_baixoupromocoes_`, ID `29009902871968723`.
- Tipo: `MEDIA_CREATOR`.
- Autenticação Instagram: verificada; acesso efetivo ao perfil confirmado.
- Introspecção de permissões: indisponível; publicação: não verificada.
- Expiração do token: não verificada.
- Nada publicado. Nenhuma escrita no banco realizada pela função.

## Validação local

Com Node 24:

```sh
node --test --test-isolation=none supabase/functions/baixou-instagram-auth-test/handler.test.mjs
```

Nove testes cobrem acesso indevido, validação administrativa remota, segredos
ausentes, métodos e parâmetros bloqueados, requests fixos de leitura, scopes
revogados/indisponíveis, erros sanitizados e perfis inválidos.

## Referências consultadas

- [Coleção oficial Meta: Instagram API com Instagram Login](https://www.postman.com/meta/instagram/folder/1z5vxzu/instagram-api-with-instagram-login)
- [Documentação oficial da coleção Meta](https://www.postman.com/meta/instagram/documentation/6yqw8pt/instagram-api)
- [Supabase: autenticação de Edge Functions](https://supabase.com/docs/guides/functions/auth)
- [Supabase: claims JWT e verificação de assinatura](https://supabase.com/docs/guides/auth/jwt-fields)
- [Supabase: listUsers exige credencial administrativa](https://supabase.com/docs/reference/javascript/auth-admin-listusers)
- [Changelog Supabase](https://supabase.com/changelog)

As páginas diretas de developers.facebook.com retornaram HTTP 429 durante a
consulta; a coleção oficial da Meta no Postman foi usada como referência
disponível. `/me` e os campos acima foram também verificados na execução real.

## Teste de criação de container — 14/10/2026

Autorizado explicitamente pelo usuário, sem publicação. Função separada:
`baixou-instagram-container-test`, com `verify_jwt = true` e a mesma verificação
administrativa do diagnóstico. Nenhuma mudança no worker Telegram ou no banco.

- Uma tentativa de `POST https://graph.instagram.com/29009902871968723/media`.
- Imagem neutra fixa: `https://placehold.co/1080x1080.jpg?text=Baixou%20Teste`.
  JPEG 1080x1080, HTTP 200 e Content-Type image/jpeg verificados antes do teste.
- Sem legenda, sem chamada a media_publish e sem URL/destino fornecidos pelo caller.
- Conta confirmada antes da criação: `_baixoupromocoes_`.
- Retorno HTTP 200, container `17926039089201655`, inicialmente IN_PROGRESS.
- Consulta posterior: HTTP 200, `status_code: FINISHED`, `published: false`.
- Isso comprova criação e processamento de conteúdo com o token atual.
  Não é comprovação de uma publicação concluída, App Review ou expiração do token.

A versão 2 desabilitou a criação (`CREATION_ENABLED = false`). POST administrativo
retorna 410; GET administrativo consulta somente o status desse container fixo.
Não há agendamento. O bloqueio em memória contra repetição da versão de teste era
por instância, não uma garantia global de idempotência; a criação foi desativada
após a única execução feita pelo agente. A janela de criação também tinha limite
de 15 minutos. Reativar exige alteração de código/deploy e nova autorização.

Seis testes locais cobrem rejeição de acesso/inputs, imagem e conta fixas,
ausência de publicação, erros sem segredos, criação desativada e consulta de status.
Os testes habilitam a criação apenas nas dependências simuladas; o entrypoint de
produção não habilita essa opção. Nenhuma credencial foi adicionada ao repositório.

Referência: https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/content-publishing/
A página direta estava inacessível pela ferramenta; a operação foi verificada
pela resposta real da API, além das referências oficiais Meta já listadas acima.

## Primeiro Story publicado — 15/10/2026

Autorizado expressamente pelo usuário nesta conversa. Conta confirmada como
BUSINESS via GET /me; antes do lançamento as listas de mídias e Stories estavam
vazias. A oferta 29756 ainda estava disponível por R$ 145,00 e com observação
recente. Nenhum token novo foi necessário.

- Vídeo v4 aprovado: 15 s, 1080x1920, logo oficial e marca d'água reduzida.
- Imagem_url do registro contém a URL HTTPS do vídeo, respeitando a coluna existente.
- Registro instagram_publicacoes: 3, formato story, situação publicada.
- Container 17926244568201655: criação HTTP 200 e processamento FINISHED.
- POST /29009902871968723/media_publish: HTTP 200.
- Mídia publicada: 18132486715685017.
- Confirmação independente via GET /29009902871968723/stories: mídia VIDEO presente,
  timestamp 2026-10-15T23:36:53+0000 (20h36min53s de Brasília).
- Persistência da confirmação: 2026-10-15T23:36:56.884Z.
- O vídeo contém URL de afiliado em texto. Não foi incluído sticker clicável.

A função separada baixou-instagram-launch-once foi invocada pelo pg_net usando
JWT de gateway e autorização aleatória específica de 45 minutos, gerada no
Vault. Só o hash dessa autorização aparece no código; o valor nunca foi retornado
pelo SQL nem enviado ao navegador. O token Instagram continuou somente nos Secrets.

A função tinha conta, oferta, registro e vídeo fixos. Compare-and-set durável
reservou o registro antes da criação e o colocou em revisão antes do envio;
falha ou resultado desconhecido nunca permite reenvio automático. Cinco testes
locais verificaram autorização, preço/tipo de conta, formato STORIES, vídeo
aprovado, bloqueio de duplicidade e estado incerto.

Após a confirmação, o entrypoint foi retirado de operação com HTTP 410,
verify_jwt continuou habilitado e não há cron. O handler fica no repositório como
registro auditável e para testes; não é invocado pelo entrypoint retirado.
Reativação requer nova autorização, novo prazo e código/deploy explícitos.
O worker Telegram e as funções de coleta não foram modificados nesta etapa.
