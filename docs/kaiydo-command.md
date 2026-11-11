# KAIYDO COMMAND — primeira versão mínima

## Entrega e limite operacional

Esta versão executa **preparação local**, com fila durável SQLite, leitura Supabase,
validação de evidências, arte SVG para revisão e exportação de rascunho para a
tabela existente `instagram_publicacoes`. Não é um funcionário autônomo completo.
Não possui cliente Meta, remetente Telegram, executor de shell, implantação nem
alteração de secrets. `publish` é sempre recusado. Nenhum endpoint antigo é reativado.

O estado fica em `.kaiydo/state.db`, fora do Git. Não há migração de produção:
usar SQLite permite validar a operação no Windows sem tocar nos trabalhadores.
O arquivo e seus diretórios são privados do operador. A aprovação é uma ação de
operador local confiável, não autenticação multiusuário. Quem controla o arquivo
ou o código pode alterar o sistema; a auditoria local não é inviolável contra o
administrador do computador.

## Investigação realizada em 10/11/2026, horário de Brasília

- GitHub: `main` em `c4aa707`, Instagram em `db5fadd`. Branch de trabalho
  `feature/kaiydo-command-mvp` parte da Instagram e incorpora `origin/main`.
  Os trabalhadores e migrations existentes permanecem intactos.
- Supabase: projeto `xxskmxhpzbqzxoaffiul`, inventário somente leitura.
  638 publicações Telegram confirmadas. Instagram: registros 1 e 2 em revisão,
  3 Story publicado em 15/10 e 4 feed publicado em 26/10. Aprovações antigas
  não são autorizações para uma nova publicação.
- Seis cron jobs ativos: ML, Shopee, worker Telegram, faxina, descoberta, vigia.
  A função Shopee v12 está no ambiente remoto e não consta desta árvore Git.
  Nunca redeployar o projeto inteiro a partir deste checkout.
- Há também funções remotas Storrito e `baixou-instagram-controlado` v2 ausentes
  do repositório. O código remoto deste último foi inspecionado: entrypoint com
  `publishingAllowed: false`, preview sem Meta e publicação com validação de
  fingerprint, imagem JPEG imutável, aprovação e reserva condicional.
  **Nenhuma função foi invocada.** Estado ACTIVE não significa publicação liberada.
- Tabelas e colunas verificadas: `ofertas`, `historico_precos`, `publicacoes`,
  `instagram_publicacoes`. Todas com RLS. A tabela Instagram não tem políticas
  de cliente comum; não abrir acesso público para fazer esta integração funcionar.
- Execuções recentes de coleta concluídas; erros de rede históricos identificados.
  Advisors apontam funções SECURITY DEFINER acessíveis a anon/authenticated,
  incluindo `shopee_vantagem_de_preco` e `vantagem_de_preco_base`.
  Revisar isso separadamente: não houve alteração de permissões nesta entrega.
  [Orientação do advisor](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable).
- A conversa referenciada não devolveu anexos. A logo oficial não está disponível
  como arquivo fonte. Nenhum desenho substituto foi criado ou extraído de outra arte.

## Regras da primeira versão

`command/policy.json` é a política explícita versionada. Alterá-la invalida a
aprovação para encaminhar rascunhos já preparados.

| Ação | Autonomia |
|---|---|
| Ler as quatro tabelas permitidas | Automática, GET apenas |
| Validar oferta e preparar arte local | Automática |
| Exportar SQL de rascunho | Aprovação local do hash exato, com prazo |
| Executar SQL no Supabase | Manual, com autorização específica; nunca pelo agente |
| Publicar Instagram / enviar notificação externa | Desabilitada nesta versão |
| Alterar secrets, cron ou implantar | Desabilitada nesta versão |

As condições conservadoras de seleção são:

1. Publicação Telegram confirmada nas últimas 24 horas, com id de mensagem e
   mesma oferta; qualquer registro Instagram existente para a oferta bloqueia.
2. Disponível, BRL, não expirada, sem cupom a validar, observação até 30 minutos.
3. Última leitura do histórico confirma preço atual e disponibilidade. Existe
   preço anterior maior realmente observado nos últimos 30 dias, em horário
   anterior ao atual. Usa o último preço maior observado, nunca `preco_original`
   da loja. Percentual é calculado e arredondado para baixo, sem inventar desconto.
4. Link HTTPS em allowlist exata de afiliados; imagem em CDN oficial. Sem
   credenciais, parâmetros, fragmentos, portas, destinos livres ou redirects.
5. Logo PNG oficial fornecida pelo operador, conferida por SHA256. Isso verifica
   os bytes escolhidos pelo operador, não autentica automaticamente sua origem.
6. Imagem original obtida com limite de bytes e tempo, PNG/JPEG; os bytes originais
   e os da logo são incorporados ao SVG sem redesenhar produto ou marca.

A leitura REST olha as 20 publicações mais recentes e até 1.000 leituras de preço
por oferta. É uma janela conservadora, não varredura de todo o histórico. Pode
bloquear uma oferta válida por falta de evidência nessa janela. Não publica para
compensar falta de informação. Disponibilidade e preço são os observados pelo
coletor; não se afirma verificação em tempo real no checkout do marketplace.
O domínio do encurtador é validado; a titularidade da conta afiliada e o destino
final do link ainda precisam de conferência editorial.

## Fila, estado e auditoria

`queued → running → ready | blocked | failed`. Cada tarefa tem chave única
`instagram:feed:<publicacao_telegram_id>:<hash_conteudo>`. Reservas usam transação
`BEGIN IMMEDIATE`, token e prazo de 120 s. Um trabalhador vencido não consegue
finalizar a tarefa. Após morte do processo, a reserva vencida pode repetir apenas
preparação local; limite de três tentativas. Falha determinística fica bloqueada,
sem loop. Nova evidência de uma tarefa bloqueada permite reavaliação no próximo sync.
Uma tarefa ready válida não é sobrescrita. Quando vencer e houver nova evidência,
o próximo sync a reenfileira e invalida aprovações anteriores; o artefato anterior
fica preservado na tabela `artifacts`, com seu hash registrado na auditoria.

Tabelas locais: `tasks`, `audit`, `notifications`, `approvals`, `artifacts`. Mudança de estado,
auditoria e notificação são gravadas juntas. Auditoria tem triggers contra
UPDATE/DELETE. Notificações de sucesso, erro e bloqueio são consultáveis localmente;
não há envio externo. Exceções externas são substituídas por códigos seguros.
Não colocar tokens na linha de comando, no arquivo de evidências ou nos logs.

Idempotência da fila vale para processos que compartilham **o mesmo banco local**.
SQLite em compartilhamento de rede e sincronização por OneDrive não são suportados.
Desktop e notebook devem ter um único operador ativo ou bancos independentes sem
encaminhamento simultâneo. O SQL usa advisory lock por oferta e não cria segundo
rascunho se já houver registro Instagram. Isso coordena apenas outros imports que
respeitam o mesmo lock; processos externos legados não participam dessa garantia.

## Executar no Windows desktop ou notebook

Python 3.11 ou posterior; testes desta entrega em Python 3.14.7 e Node 24.18.0.
Somente biblioteca padrão Python, sem instalação de pacotes. Abra PowerShell na
raiz do checkout isolado.

```powershell
python -m unittest command.test_command -v
python -m command.cli status
python -m command.cli notifications
```

Para leitura online, disponibilize `KAIYDO_SUPABASE_READ_KEY` apenas no ambiente do
processo, por seu gerenciador de credenciais. O adaptador aceita a credencial já
existente de backend; não a imprime nem cria secrets. Uma chave publishable/anon
não garante acesso pela RLS. Ideal futuro: uma identidade de backend com acesso
somente às quatro leituras necessárias. Service role continua sendo uma chave
privilegiada mesmo quando este programa a utiliza exclusivamente para GET.
Não é preciso expor nem alterar chave de produção para rodar os testes offline.

```powershell
python -m command.cli sync
$logoHash = (Get-FileHash -Algorithm SHA256 'C:\Baixou\logo-oficial.png').Hash.ToLower()
python -m command.cli run --logo 'C:\Baixou\logo-oficial.png' --logo-sha256 $logoHash
python -m command.cli status
python -m command.cli export 1 --out '.kaiydo\review\1'
```

`run` processa uma tarefa. `sync` não processa nem publica. Sem logo oficial,
`run` registra `official_logo_missing`. Estado `ready` significa pronto para
**revisão**, nunca pronto para publicação. Revise `preview.svg`, `draft.json`,
produto, preço, origem do preço anterior, imagem e link. A legenda do feed não
torna o link clicável; destino na bio exige revisão operacional.

Para encaminhar rascunho, depois de revisar o hash retornado por `export`:

```powershell
python -m command.cli approve-draft 1 --hash '<hash_exato>' --actor 'operador'
python -m command.cli handoff-sql 1 --out '.kaiydo\review\1\handoff.sql'
```

Isso apenas gera SQL, **não o executa**. A aprovação vence no máximo em 30 minutos
e antes disso se a evidência envelhecer. O SQL revalida preço, oferta, histórico,
estoque e fonte Telegram, insere apenas `rascunho`, sem `imagem_url`. A operação
usa a tabela atual sem migrations. Antes de executá-la, revisar e autorizar a
escrita no ambiente escolhido. O SQL ainda precisa de teste de integração em
Postgres isolado; não foi executado em produção nem validado por um servidor local.

## Integração Instagram e implantação

O contrato do rascunho corresponde à tabela existente, sem alterar os registros
1–4. O SVG é arte de revisão, não mídia aceita pela Meta. Depois de obter a logo,
revisar visualmente a composição, renderizar um JPEG 1080×1350, conferir os bytes
e hospedar em URL imutável. Só depois, sob aprovação separada, preencher a imagem
do rascunho. O preview remoto `baixou-instagram-controlado` exige JPEG e sua
publicação exige URL de commit imutável; este programa não o chama e não libera
essa função. A aprovação local de encaminhamento **não** equivale à aprovação
editorial nem ao fingerprint da publicação Meta.

Para uso contínuo inicial, manter um checkout fixo e o estado local persistente.
O script `scripts/run-command.ps1` faz um ciclo limitado, termina e deixa o
histórico no banco. Executá-lo manualmente primeiro. Agendador do Windows é uma
implantação opcional, somente depois de consentimento: usuário dedicado, diretório
de trabalho fixo, sem sobrepor execuções, credencial de leitura no ambiente seguro,
sem token Instagram. Não foi criada nenhuma tarefa agendada nesta entrega.

Não usar `supabase db reset`, deploy global ou aplicar todas as migrations deste
repositório sobre produção: há deriva remota conhecida. Para futura implantação
em servidor, usar volume local persistente, uma instância ativa, a mesma política
e testes; portabilidade para Edge Functions requer fila Postgres e autenticação
própria e está fora deste MVP. Rollback: parar somente o novo processo/agendamento,
preservar o SQLite para auditoria. Os trabalhadores antigos seguem independentes.

## Verificação e pendências

18 testes novos passaram: preço observado, estoque, fonte Telegram, evidência
vencida, URLs, duplicidade persistente, disputa concorrente, reserva vencida,
token antigo, orçamento de retentativas, logo ausente, falha sanitizada,
aprovação/hash/prazo/política, SQL com título hostil, proibição de ações sensíveis
e auditoria. Mais 20 testes existentes de Instagram passaram.

Uma amostra real somente leitura das três últimas publicações foi processada
localmente: oferta 14387 bloqueada por ausência de preço anterior maior na janela;
1598453 e 29720 passaram nas evidências de preço naquele instante e ficaram
bloqueadas por logo ausente. Não constituem recomendação atual de publicação:
preços e prazos precisam ser revalidados. Nenhuma oferta foi gravada no Supabase.

Pendências: arquivo oficial da logo; revisão visual com arte real; JPEG final e
hospedagem imutável; teste Postgres do handoff; credencial de leitura e teste REST
com o ambiente autorizado; sincronizar o código remoto ausente para controle de
versão em trabalho separado; eventual aprovação de implantação/agendamento;
canal privado para notificações externas; publicador e suas autorizações de
conta/regras/limites. Não há publicação automática nesta entrega.
