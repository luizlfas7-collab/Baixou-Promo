"""No Meta client, message sender, production writes or arbitrary task execution."""
import base64
import hashlib
import html
import json
import sqlite3
import time
import textwrap
import uuid
from contextlib import contextmanager
from datetime import datetime
from decimal import Decimal, InvalidOperation, ROUND_DOWN
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).parent


def default_brand():
    root = ROOT.parent / 'assets' / 'brand'
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    asset = manifest['variants'][manifest['default']]
    return root / asset['file'], asset['sha256']


class Blocked(Exception):
    pass


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def policy():
    return json.loads((ROOT / "policy.json").read_text(encoding="utf-8"))


def authorize(action, approved=False):
    p = policy()
    if action in p["disabled_actions"]:
        raise Blocked("action_disabled")
    if action in p["automatic_actions"]:
        return
    if action in p["approval_required"] and approved:
        return
    raise Blocked("approval_required_or_unknown_action")


def stamp(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError()
        return parsed.timestamp()
    except (ValueError, TypeError, AttributeError):
        raise Blocked("invalid_timestamp") from None


def recent(value, now, seconds):
    age = now - stamp(value)
    return 0 <= age <= seconds


def money(value):
    try:
        result = Decimal(str(value))
        if not result.is_finite() or result <= 0 or result != result.quantize(Decimal("0.01")):
            raise ValueError()
        return result
    except (InvalidOperation, ValueError):
        raise Blocked("invalid_price") from None


def valid_url(value, hosts):
    try:
        u = urlsplit(value)
        return (u.scheme == "https" and u.hostname in hosts and not u.username
                and not u.password and not u.port and not u.query and not u.fragment
                and len(u.path) > 1 and not any(c.isspace() for c in value)
                and "%" not in value and "\\" not in value)
    except (ValueError, TypeError, AttributeError):
        return False


def validate(data, now=None):
    """Evidence comes from backend reads, never from an LLM price assertion."""
    now = time.time() if now is None else now
    p = policy()
    o, pub = data["offer"], data["telegram"]
    if (pub["canal"] != "telegram" or pub["situacao"] != "publicada"
            or not pub.get("id_mensagem_externa") or pub["oferta_id"] != o["id"]):
        raise Blocked("telegram_not_confirmed")
    if not recent(pub["publicado_em"], now, p["telegram_max_age_seconds"]):
        raise Blocked("telegram_stale")
    if data.get("instagram_exists"):
        raise Blocked("instagram_already_exists_requires_review")
    if o.get("disponivel") is not True or o.get("moeda") != "BRL":
        raise Blocked("unavailable_or_currency")
    if o.get("expira_em") and stamp(o["expira_em"]) <= now:
        raise Blocked("offer_expired")
    if o.get("codigo_cupom"):
        raise Blocked("coupon_requires_manual_validation")
    if not recent(o["visto_ultimo_em"], now, p["max_age_seconds"]):
        raise Blocked("offer_stale")
    if not valid_url(o.get("url_afiliado"), p["affiliate_hosts"]):
        raise Blocked("invalid_affiliate")
    if not valid_url(o.get("url_imagem"), p["image_hosts"]):
        raise Blocked("invalid_original_image")
    if not isinstance(o.get("titulo"), str) or not 1 <= len(o["titulo"]) <= 240:
        raise Blocked("invalid_title")
    current = money(o["preco_atual"])
    all_history = [h for h in data["history"] if h["oferta_id"] == o["id"]]
    all_history.sort(key=lambda h: stamp(h["observado_em"]))
    if not all_history or all_history[-1].get("disponivel") is not True or all_history[-1].get("moeda") != "BRL" or not recent(all_history[-1]["observado_em"], now, p["max_age_seconds"]) or money(all_history[-1]["preco"]) != current:
        raise Blocked("current_price_not_confirmed")
    history = [h for h in data["history"] if h["oferta_id"] == o["id"]
               and h.get("moeda") == "BRL" and h.get("disponivel") is True
               and recent(h["observado_em"], now, p["history_window_seconds"])]
    history.sort(key=lambda h: stamp(h["observado_em"]))
    if not history or money(history[-1]["preco"]) != current or not recent(
            history[-1]["observado_em"], now, p["max_age_seconds"]):
        raise Blocked("current_price_not_confirmed")
    # Use only a price actually observed earlier, never the store's preco_original.
    previous = [h for h in history[:-1] if money(h["preco"]) > current
                and stamp(h["observado_em"]) < stamp(history[-1]["observado_em"])]
    if not previous:
        raise Blocked("previous_price_not_observed")
    before = previous[-1]
    original = money(before["preco"])
    discount = ((original-current)*100/original).quantize(Decimal("1"), rounding=ROUND_DOWN)
    return {"publicacao_telegram_id": pub["id"], "oferta_id": o["id"],
            "formato": "feed", "situacao": "rascunho", "titulo": o["titulo"],
            "preco_anterior_observado": str(original), "preco_atual": str(current),
            "desconto_percentual": str(discount), "url_afiliado": o["url_afiliado"],
            "imagem_original_url": o["url_imagem"], "hash_conteudo_oferta": o["hash_conteudo"],
            "historico_anterior_id": before["id"], "historico_atual_id": history[-1]["id"],
            "legenda": f'{o["titulo"]}\nPreço anterior observado: R$ {original:.2f}\n'
            f'Agora: R$ {current:.2f}\n{discount}% de queda sobre o preço observado.\n'
            f'{o["url_afiliado"]}\nPUBLICIDADE • LINK DE AFILIADO\nPreço e estoque sujeitos a alteração.'}


class Store:
    def __init__(self, path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, timeout=30, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS tasks (
          id INTEGER PRIMARY KEY, task_key TEXT UNIQUE NOT NULL, input TEXT NOT NULL,
          state TEXT NOT NULL CHECK(state IN ('queued','running','blocked','ready','failed')),
          attempts INTEGER NOT NULL DEFAULT 0, token TEXT, lease REAL,
          result TEXT, result_hash TEXT, reason TEXT, updated REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS audit (
          id INTEGER PRIMARY KEY, task_id INTEGER REFERENCES tasks(id), event TEXT NOT NULL,
          detail TEXT NOT NULL, at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS notifications (
          id INTEGER PRIMARY KEY, audit_id INTEGER UNIQUE REFERENCES audit(id),
          kind TEXT NOT NULL, code TEXT NOT NULL, at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS approvals (
          task_id INTEGER REFERENCES tasks(id), result_hash TEXT NOT NULL,
          policy_hash TEXT NOT NULL, actor TEXT NOT NULL, expires REAL NOT NULL,
          PRIMARY KEY(task_id,result_hash));
        CREATE TABLE IF NOT EXISTS artifacts (
          hash TEXT PRIMARY KEY, task_id INTEGER REFERENCES tasks(id),
          content TEXT NOT NULL, at REAL NOT NULL);
        CREATE TRIGGER IF NOT EXISTS audit_no_update BEFORE UPDATE ON audit
          BEGIN SELECT RAISE(ABORT,'append_only'); END;
        CREATE TRIGGER IF NOT EXISTS audit_no_delete BEFORE DELETE ON audit
          BEGIN SELECT RAISE(ABORT,'append_only'); END;
        ''')

    @contextmanager
    def tx(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def event(self, task, event, detail, notify=None):
        row = self.db.execute("INSERT INTO audit(task_id,event,detail,at) VALUES(?,?,?,?)",
                              (task, event, canonical(detail), time.time()))
        if notify:
            self.db.execute("INSERT INTO notifications(audit_id,kind,code,at) VALUES(?,?,?,?)",
                            (row.lastrowid, notify, event, time.time()))

    def enqueue(self, data):
        authorize("prepare_local_draft")
        key = f'instagram:feed:{data["telegram"]["id"]}:{data["offer"]["hash_conteudo"]}'
        with self.tx():
            old = self.db.execute("SELECT * FROM tasks WHERE task_key=?", (key,)).fetchone()
            if old:
                expired_ready = old["state"] == "ready" and json.loads(old["result"])["valid_until"] <= time.time()
                if (old["state"] in ("blocked", "failed") or expired_ready) and old["input"] != canonical(data):
                    self.db.execute("UPDATE tasks SET input=?,state='queued',attempts=0,result=NULL,result_hash=NULL,updated=? WHERE id=?",
                                    (canonical(data), time.time(), old["id"]))
                    self.db.execute("DELETE FROM approvals WHERE task_id=?", (old["id"],))
                    self.event(old["id"], "evidence_refreshed", {"previous_artifact_hash": old["result_hash"]})
                return old["id"]
            row = self.db.execute("INSERT INTO tasks(task_key,input,state,updated) VALUES(?,?,'queued',?)",
                                  (key, canonical(data), time.time()))
            self.event(row.lastrowid, "enqueued", {})
            return row.lastrowid

    def claim(self):
        now = time.time()
        with self.tx():
            expired = self.db.execute("SELECT id,attempts FROM tasks WHERE state='running' AND lease<?", (now,)).fetchall()
            for row in expired:
                state = "failed" if row["attempts"] >= policy()["max_attempts"] else "queued"
                self.db.execute("UPDATE tasks SET state=?,token=NULL,lease=NULL,reason='lease_expired' WHERE id=?", (state, row["id"]))
                self.event(row["id"], "lease_expired", {}, "error")
            row = self.db.execute("SELECT * FROM tasks WHERE state='queued' ORDER BY id LIMIT 1").fetchone()
            if not row:
                return None
            token = uuid.uuid4().hex
            self.db.execute("UPDATE tasks SET state='running',token=?,lease=?,attempts=attempts+1,updated=? WHERE id=?",
                            (token, now+policy()["lease_seconds"], now, row["id"]))
            self.event(row["id"], "claimed", {})
            return dict(row) | {"token": token}

    def finish(self, row, result=None, reason=None, failed=False):
        state = "failed" if failed else "blocked" if reason else "ready"
        with self.tx():
            changed = self.db.execute("UPDATE tasks SET state=?,result=?,result_hash=?,reason=?,token=NULL,lease=NULL,updated=? WHERE id=? AND state='running' AND token=? AND lease>=?",
                (state, canonical(result) if result else None, digest(result) if result else None,
                 reason, time.time(), row["id"], row["token"], time.time())).rowcount
            if changed != 1:
                raise Blocked("lease_lost")
            if result:
                self.db.execute("INSERT OR IGNORE INTO artifacts VALUES(?,?,?,?)",
                                (digest(result), row["id"], canonical(result), time.time()))
            self.event(row["id"], state, {"reason": reason, "result_hash": digest(result) if result else None},
                       "success" if state == "ready" else "error" if failed else "blocked")

    def approve(self, task, expected_hash, actor, now=None):
        now = time.time() if now is None else now
        if not actor or len(actor) > 120 or any(ord(c) < 32 for c in actor):
            raise Blocked("invalid_actor")
        with self.tx():
            row = self.db.execute("SELECT * FROM tasks WHERE id=?", (task,)).fetchone()
            if not row or row["state"] != "ready" or row["result_hash"] != expected_hash:
                raise Blocked("artifact_changed_or_not_ready")
            result = json.loads(row["result"])
            if result["policy_hash"] != digest(policy()) or result["valid_until"] <= now:
                raise Blocked("artifact_expired_or_policy_changed")
            self.db.execute("INSERT OR REPLACE INTO approvals VALUES(?,?,?,?,?)",
                            (task, expected_hash, digest(policy()), actor, min(now+1800, result["valid_until"])))
            self.event(task, "draft_handoff_approved", {"actor": actor, "hash": expected_hash})


def logo_asset(path, expected_sha):
    if not path or not expected_sha:
        raise Blocked("official_logo_missing")
    raw = Path(path).read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected_sha or not raw.startswith(b"\x89PNG\r\n\x1a\n") or len(raw) > 2000000:
        raise Blocked("official_logo_hash_or_format")
    return "data:image/png;base64," + base64.b64encode(raw).decode()


def render(draft, logo, product):
    """SVG review artifact embeds exact source bytes. No generated product or logo."""
    esc = html.escape
    title = draft["titulo"]
    lines = textwrap.wrap(title, width=38, break_long_words=False, break_on_hyphens=False)
    compact = len(lines) > 4
    if compact:
        lines = textwrap.wrap(title, width=52, break_long_words=True, break_on_hyphens=False)
    previous_price = f"{Decimal(draft['preco_anterior_observado']):.2f}".replace('.', ',')
    current_price = f"{Decimal(draft['preco_atual']):.2f}".replace('.', ',')
    line_height = 32 if compact else 42
    title_size = 28 if compact else 34
    text = "".join(f'<tspan x="60" dy="{line_height}">{esc(line)}</tspan>' for line in lines)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1350" viewBox="0 0 1080 1350">
<rect width="1080" height="1350" fill="#080808"/>
<image href="{logo}" x="60" y="20" width="640" height="170" preserveAspectRatio="xMinYMid meet"/>
<rect x="60" y="200" width="960" height="590" fill="white"/>
<image href="{product}" x="70" y="210" width="940" height="570" preserveAspectRatio="xMidYMid meet"/>
<text y="820" fill="#fff5e2" font-size="{title_size}" font-family="Arial">{text}</text>
<text x="60" y="1040" fill="#ff7900" font-size="54" font-family="Arial" font-weight="bold">{draft['desconto_percentual']}% DE QUEDA</text>
<text x="60" y="1085" fill="#fff5e2" font-size="25" font-family="Arial">sobre o preço anterior observado</text>
<rect x="0" y="1165" width="1080" height="185" fill="#ff7900"/>
<text x="60" y="1210" fill="#080808" font-size="28" font-family="Arial">Anterior observado: R$ {previous_price}</text>
<text x="60" y="1280" fill="#080808" font-size="58" font-family="Arial">Agora R$ {current_price}</text>
<text x="60" y="1330" fill="#080808" font-size="22" font-family="Arial">PUBLICIDADE • LINK DE AFILIADO • Preço e estoque sujeitos a alteração</text></svg>'''


def process_one(store, logo=None, logo_sha=None, image_loader=None):
    row = store.claim()
    if not row:
        return None
    try:
        data = json.loads(row["input"])
        draft = validate(data)
        brand = logo_asset(logo, logo_sha)
        if image_loader is None:
            raise Blocked("original_image_fetch_required")
        product = image_loader(draft["imagem_original_url"])
        now = time.time()
        valid_until = min(stamp(data["offer"]["visto_ultimo_em"])+policy()["max_age_seconds"],
                          stamp(data["telegram"]["publicado_em"])+policy()["telegram_max_age_seconds"])
        if data["offer"].get("expira_em"):
            valid_until = min(valid_until, stamp(data["offer"]["expira_em"]))
        result = {"draft": draft, "svg": render(draft, brand, product), "logo_sha256": logo_sha,
                  "policy_hash": digest(policy()), "valid_until": valid_until, "prepared_at": now,
                  "publishable": False, "next_step": "review_and_render_jpeg"}
        store.finish(row, result=result)
    except Blocked as exc:
        store.finish(row, reason=str(exc))
    except Exception:
        # Never persist raw exceptions, upstream bodies or credentials.
        store.finish(row, reason="preparation_failed", failed=True)
    return row["id"]
