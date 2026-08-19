-- Funcoes de gatilho nao devem ser chamaveis pela API REST.
-- Os gatilhos continuam funcionando: eles rodam no contexto do dono da tabela.
revoke execute on function public.trata_novo_usuario() from anon, authenticated, public;
revoke execute on function public.toca_atualizado_em() from anon, authenticated, public;
