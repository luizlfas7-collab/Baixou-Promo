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
