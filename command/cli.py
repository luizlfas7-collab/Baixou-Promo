"""Run with python -m command.cli. Outputs never contain keys or raw errors."""
import argparse
import base64
import json
import sys
import time
from pathlib import Path

from .core import Blocked, Store, authorize, canonical, default_brand, digest, policy, process_one, validate
from .source import SupabaseReader, original_image


def handoff_sql(store, task):
    """Export only. Does not connect to or write to the production database."""
    row = store.db.execute("SELECT * FROM tasks WHERE id=?", (task,)).fetchone()
    if not row or row["state"] != "ready":
        raise Blocked("not_ready")
    result = json.loads(row["result"])
    approval = store.db.execute("SELECT * FROM approvals WHERE task_id=? AND result_hash=?",
                                (task, row["result_hash"])).fetchone()
    approved = bool(approval and approval["expires"] > time.time() and
                    approval["policy_hash"] == digest(policy()) and result["valid_until"] > time.time())
    authorize("handoff_draft", approved)
    draft = result["draft"]
    # All values remain data in one quoted JSON literal, including untrusted product titles.
    payload = base64.b64encode(canonical(draft).encode()).decode()
    return f'''-- KAIYDO: manual, approval-bound DRAFT handoff. Never executes a publisher.
-- Artifact SHA256: {row['result_hash']}
-- Run only after approving this exact operation. No schema/secret/cron changes.
BEGIN;
SET LOCAL standard_conforming_strings = on;
DO $kaiydo$
DECLARE d jsonb := convert_from(decode('{payload}','base64'),'UTF8')::jsonb; o public.ofertas%ROWTYPE;
BEGIN
  PERFORM pg_advisory_xact_lock(77901, (d->>'oferta_id')::integer);
  IF extract(epoch from now()) > {result['valid_until']} THEN
    RAISE EXCEPTION 'kaiydo_expired';
  END IF;
  SELECT * INTO STRICT o FROM public.ofertas WHERE id=(d->>'oferta_id')::bigint FOR SHARE;
  IF o.hash_conteudo IS DISTINCT FROM d->>'hash_conteudo_oferta'
    OR o.preco_atual IS DISTINCT FROM (d->>'preco_atual')::numeric
    OR o.disponivel IS DISTINCT FROM true OR o.moeda <> 'BRL'
    OR o.url_afiliado IS DISTINCT FROM d->>'url_afiliado'
    OR o.url_imagem IS DISTINCT FROM d->>'imagem_original_url'
    OR o.codigo_cupom IS NOT NULL
    OR o.visto_ultimo_em < now()-interval '30 minutes' OR o.visto_ultimo_em > now()
    OR (o.expira_em IS NOT NULL AND o.expira_em <= now()) THEN
    RAISE EXCEPTION 'kaiydo_offer_changed';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.publicacoes p WHERE p.id=(d->>'publicacao_telegram_id')::bigint
    AND p.oferta_id=o.id AND p.canal='telegram' AND p.situacao='publicada'
    AND p.id_mensagem_externa IS NOT NULL AND p.publicado_em BETWEEN now()-interval '24 hours' AND now()) THEN
    RAISE EXCEPTION 'kaiydo_telegram_not_confirmed';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.historico_precos a, public.historico_precos b
    WHERE a.id=(d->>'historico_anterior_id')::bigint AND b.id=(d->>'historico_atual_id')::bigint
    AND a.oferta_id=o.id AND b.oferta_id=o.id AND a.preco=(d->>'preco_anterior_observado')::numeric
    AND b.preco=o.preco_atual AND a.preco>b.preco AND a.observado_em<b.observado_em
    AND a.moeda='BRL' AND b.moeda='BRL' AND a.disponivel AND b.disponivel
    AND a.observado_em>=now()-interval '30 days'
    AND b.observado_em BETWEEN now()-interval '30 minutes' AND now()) THEN
    RAISE EXCEPTION 'kaiydo_price_evidence_changed';
  END IF;
  -- Any existing format/status for this offer requires review, not a second draft.
  IF NOT EXISTS(SELECT 1 FROM public.instagram_publicacoes WHERE oferta_id=o.id) THEN
    INSERT INTO public.instagram_publicacoes(publicacao_telegram_id,oferta_id,formato,situacao,legenda,url_afiliado)
    VALUES((d->>'publicacao_telegram_id')::bigint,o.id,'feed','rascunho',d->>'legenda',d->>'url_afiliado');
  END IF;
END $kaiydo$;
COMMIT;
-- imagem_url intentionally NULL: review SVG, render/upload approved JPEG separately.
'''


def main(argv=None):
    parser = argparse.ArgumentParser(description="KAIYDO COMMAND — preparação local; publicação desabilitada")
    parser.add_argument("--db", default=".kaiydo/state.db")
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("sync", help="Ler ofertas Supabase e enfileirar localmente")
    batch = commands.add_parser('cycle', help='Selecionar ofertas e gerar JPEG + legenda locais')
    batch.add_argument('--out', default='.kaiydo/review')
    batch.add_argument('--limit', type=int, default=1)
    run = commands.add_parser("run", help="Processar uma tarefa local")
    run.add_argument("--logo")
    run.add_argument("--logo-sha256")
    commands.add_parser("status")
    commands.add_parser("notifications")
    export = commands.add_parser("export")
    export.add_argument("task", type=int)
    export.add_argument("--out", required=True)
    approve = commands.add_parser("approve-draft")
    approve.add_argument("task", type=int)
    approve.add_argument("--hash", required=True)
    approve.add_argument("--actor", required=True)
    handoff = commands.add_parser("handoff-sql")
    handoff.add_argument("task", type=int)
    handoff.add_argument("--out", required=True)
    commands.add_parser("publish", help="Sempre bloqueado nesta versão")
    args = parser.parse_args(argv)
    store = Store(args.db)
    try:
        if args.action == 'cycle':
            from .pipeline import cycle
            print(canonical(cycle(store, SupabaseReader().candidates(), args.out, args.limit)))
        elif args.action == "sync":
            count = 0
            for evidence in SupabaseReader().candidates():
                store.enqueue(evidence)
                count += 1
            print(canonical({"enqueued_or_existing": count}))
        elif args.action == "run":
            if not args.logo and not args.logo_sha256:
                args.logo, args.logo_sha256 = default_brand()
            print(canonical({"task": process_one(store, args.logo, args.logo_sha256, original_image)}))
        elif args.action in ("status", "notifications"):
            query = ("SELECT id,state,attempts,reason,result_hash,updated FROM tasks ORDER BY id" if args.action == "status"
                     else "SELECT id,kind,code,at FROM notifications ORDER BY id")
            print(canonical([dict(row) for row in store.db.execute(query)]))
        elif args.action == "export":
            row = store.db.execute("SELECT result,result_hash FROM tasks WHERE id=? AND state='ready'", (args.task,)).fetchone()
            if not row:
                raise Blocked("not_ready")
            dest = Path(args.out)
            dest.mkdir(parents=True, exist_ok=True)
            result = json.loads(row["result"])
            (dest / "preview.svg").write_text(result["svg"], encoding="utf-8")
            (dest / "draft.json").write_text(canonical(result | {"artifact_hash": row["result_hash"]}), encoding="utf-8")
            print(canonical({"artifact_hash": row["result_hash"], "publishable": False}))
        elif args.action == "approve-draft":
            store.approve(args.task, args.hash, args.actor)
            print("draft_handoff_approved; publication_not_authorized")
        elif args.action == "handoff-sql":
            sql = handoff_sql(store, args.task)
            Path(args.out).write_text(sql, encoding="utf-8")
            with store.tx():
                store.event(args.task, "handoff_sql_exported", {})
            print("sql_exported_not_executed")
        elif args.action == "publish":
            authorize("publish_instagram")
    except Exception as exc:
        code = str(exc) if isinstance(exc, Blocked) else "operation_failed"
        with store.tx():
            store.event(None, code, {"action": args.action}, "blocked" if isinstance(exc, Blocked) else "error")
        print(canonical({"ok": False, "code": code}), file=sys.stderr)
        return 2
    finally:
        store.db.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
