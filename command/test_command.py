import base64
import copy
import hashlib
import json
import tempfile
import time
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from .cli import handoff_sql, main
from .core import Blocked, Store, authorize, digest, policy, process_one, validate, valid_url
from .source import NoRedirect, SupabaseReader, original_image


def iso(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat()


def evidence(now=None):
    now = time.time() if now is None else now
    return {"offer": {"id": 7, "titulo": "Produto <original>", "moeda": "BRL", "preco_atual": "70.00",
            "preco_original": "9999.00", "disponivel": True, "visto_ultimo_em": iso(now-30),
            "url_afiliado": "https://meli.la/abcd", "url_imagem": "https://http2.mlstatic.com/test.jpg",
            "hash_conteudo": "abc", "codigo_cupom": None, "expira_em": None},
            "telegram": {"id": 3, "oferta_id": 7, "canal": "telegram", "situacao": "publicada",
                         "id_mensagem_externa": "19", "publicado_em": iso(now-60)},
            "history": [{"id": 1, "oferta_id": 7, "preco": "100.00", "moeda": "BRL", "disponivel": True, "observado_em": iso(now-300)},
                        {"id": 2, "oferta_id": 7, "preco": "70.00", "moeda": "BRL", "disponivel": True, "observado_em": iso(now-30)}],
            "instagram_exists": False}


class CommandTests(unittest.TestCase):
    def setUp(self):
        scratch = Path('.kaiydo/tests').resolve()
        scratch.mkdir(parents=True, exist_ok=True)
        self.path = scratch / uuid.uuid4().hex
        self.path.mkdir()
        self.store = Store(self.path / "state.db")
        # Test-only fixture; never represents the official Baixou logo.
        self.logo = self.path / "fixture.png"
        self.logo.write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII="))
        self.sha = hashlib.sha256(self.logo.read_bytes()).hexdigest()

    def tearDown(self):
        self.store.db.close()

    def ready(self, data=None):
        task = self.store.enqueue(data or evidence())
        process_one(self.store, self.logo, self.sha, lambda _: "data:image/png;base64,fixture")
        return task, self.store.db.execute("SELECT * FROM tasks WHERE id=?", (task,)).fetchone()

    def test_observed_discount_ignores_store_original(self):
        result = validate(evidence())
        self.assertEqual(result["desconto_percentual"], "30")
        self.assertEqual(result["preco_anterior_observado"], "100.00")
        self.assertNotIn("9999", result["legenda"])

    def test_rejects_unsafe_evidence(self):
        mutations = [lambda d: d["offer"].update(disponivel=False),
                     lambda d: d["offer"].update(preco_atual="NaN"),
                     lambda d: d["offer"].update(preco_atual="-1"),
                     lambda d: d["offer"].update(visto_ultimo_em=iso(time.time()-1900)),
                     lambda d: d["offer"].update(expira_em=iso(time.time()-1)),
                     lambda d: d["offer"].update(codigo_cupom="CUPOM"),
                     lambda d: d["telegram"].update(situacao="removida"),
                     lambda d: d["telegram"].update(id_mensagem_externa=None),
                     lambda d: d["telegram"].update(oferta_id=8),
                     lambda d: d.update(instagram_exists=True),
                     lambda d: d["history"].pop(0),
                     lambda d: d["history"][-1].update(preco="69.00"),
                     lambda d: d["history"][-1].update(disponivel=False),
                     lambda d: d["history"][-1].update(observado_em=iso(time.time()+200)),
                     lambda d: d["offer"].update(url_afiliado="https://meli.la.evil.com/x"),
                     lambda d: d["offer"].update(url_imagem="http://http2.mlstatic.com/x")]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                data = evidence()
                mutate(data)
                with self.assertRaises(Blocked):
                    validate(data)

    def test_hostile_urls(self):
        for url in ["https://user:pw@meli.la/a", "https://meli.la:443/a", "https://meli.la/a?q=x", "https://meli.la/a#x", "https://meli.la/%ZZ", "https://meli.la/", "https://meli.la/a\\b"]:
            self.assertFalse(valid_url(url, ["meli.la"]), url)

    def test_enqueue_idempotent_and_persistent(self):
        data = evidence()
        first = self.store.enqueue(data)
        self.assertEqual(first, self.store.enqueue(data))
        second = Store(self.path / "state.db")
        self.assertEqual(first, second.enqueue(data))
        second.db.close()
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM audit").fetchone()[0], 1)

    def test_concurrent_claim_single_owner(self):
        self.store.enqueue(evidence())
        def claim(_):
            db = Store(self.path / "state.db")
            try:
                return db.claim()
            finally:
                db.db.close()
        with ThreadPoolExecutor(max_workers=4) as pool:
            rows = list(pool.map(claim, range(4)))
        self.assertEqual(sum(row is not None for row in rows), 1)

    def test_lease_fencing_and_recovery(self):
        self.store.enqueue(evidence())
        first = self.store.claim()
        self.store.db.execute("UPDATE tasks SET lease=0")
        second = self.store.claim()
        self.assertNotEqual(first["token"], second["token"])
        with self.assertRaises(Blocked):
            self.store.finish(first, result={"x": 1})
        self.store.finish(second, reason="test")

    def test_retry_budget_exhaustion(self):
        self.store.enqueue(evidence())
        for _ in range(3):
            self.assertIsNotNone(self.store.claim())
            self.store.db.execute("UPDATE tasks SET lease=0")
        self.assertIsNone(self.store.claim())
        self.assertEqual(self.store.db.execute("SELECT state FROM tasks").fetchone()[0], "failed")

    def test_missing_brand_blocks_and_notifies(self):
        self.store.enqueue(evidence())
        process_one(self.store)
        row = self.store.db.execute("SELECT * FROM tasks").fetchone()
        self.assertEqual(row["reason"], "official_logo_missing")
        self.assertEqual(self.store.db.execute("SELECT kind FROM notifications").fetchone()[0], "blocked")

    def test_exception_sanitized(self):
        self.store.enqueue(evidence())
        def fail(_):
            raise RuntimeError("SECRET-KEY")
        process_one(self.store, self.logo, self.sha, fail)
        all_rows = canonical_rows(self.store)
        self.assertNotIn("SECRET-KEY", all_rows)
        self.assertIn("preparation_failed", all_rows)

    def test_ready_artifact_and_explicit_hash_approval(self):
        task, row = self.ready()
        result = json.loads(row["result"])
        self.assertEqual(row["state"], "ready")
        self.assertFalse(result["publishable"])
        self.assertIn("&lt;original&gt;", result["svg"])
        self.assertIn("data:image/png;base64,", result["svg"])
        with self.assertRaises(Blocked):
            handoff_sql(self.store, task)
        with self.assertRaises(Blocked):
            self.store.approve(task, "wrong-hash", "owner")
        self.store.approve(task, row["result_hash"], "owner")
        sql = handoff_sql(self.store, task)
        self.assertIn("pg_advisory_xact_lock", sql)
        self.assertIn("'rascunho'", sql)
        self.assertNotIn("media_publish", sql)
        self.store.db.execute("UPDATE approvals SET expires=0")
        with self.assertRaises(Blocked):
            handoff_sql(self.store, task)

    def test_sql_delimiter_in_title_is_encoded(self):
        data = evidence()
        data["offer"]["titulo"] = "'$kaiydo$; DROP TABLE public.ofertas;--"
        task, row = self.ready(data)
        self.store.approve(task, row["result_hash"], "owner")
        sql = handoff_sql(self.store, task)
        self.assertNotIn("DROP TABLE", sql)
        self.assertEqual(sql.count("$kaiydo$"), 2)

    def test_policy_change_invalidates_approval(self):
        task, row = self.ready()
        self.store.approve(task, row["result_hash"], "owner")
        changed = policy() | {"version": 999}
        with patch("command.cli.policy", return_value=changed):
            with self.assertRaises(Blocked):
                handoff_sql(self.store, task)

    def test_expired_draft_cannot_be_approved(self):
        task, row = self.ready()
        with self.assertRaises(Blocked):
            self.store.approve(task, row["result_hash"], "owner", now=time.time()+3600)

    def test_expired_ready_refresh_preserves_artifact_and_revokes_approval(self):
        task, row = self.ready()
        self.store.approve(task, row["result_hash"], "owner")
        fresh = evidence()
        with patch('command.core.time.time', return_value=time.time()+3600):
            self.assertEqual(self.store.enqueue(fresh), task)
        self.assertEqual(self.store.db.execute('SELECT state FROM tasks').fetchone()[0], 'queued')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM approvals').fetchone()[0], 0)
        self.assertEqual(self.store.db.execute('SELECT hash FROM artifacts').fetchone()[0], row['result_hash'])

    def test_sensitive_actions_default_deny(self):
        for action in ["publish_instagram", "send_notification", "deploy", "change_secrets", "change_schedule", "arbitrary_shell"]:
            with self.assertRaises(Blocked):
                authorize(action, approved=True)

    def test_audit_append_only(self):
        self.store.enqueue(evidence())
        import sqlite3
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.db.execute("DELETE FROM audit")

    def test_reader_only_known_tables(self):
        with patch.dict("os.environ", {"KAIYDO_SUPABASE_READ_KEY": "test-key"}):
            reader = SupabaseReader()
        with self.assertRaises(Blocked):
            reader.rows("rpc/soltar_trava", {})

    def test_image_type_and_redirect(self):
        with patch("command.source.get", return_value=(b"<html>", "image/jpeg")):
            with self.assertRaises(Blocked):
                original_image("https://http2.mlstatic.com/image.jpg")
        with self.assertRaises(Blocked):
            NoRedirect().redirect_request(None, None, 302, None, None, "http://127.0.0.1")


def canonical_rows(store):
    return json.dumps({table: [dict(r) for r in store.db.execute("SELECT * FROM " + table)]
                       for table in ["tasks", "audit", "notifications"]})


if __name__ == "__main__":
    unittest.main()
