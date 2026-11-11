"""Read-only Supabase adapter; no RPC, POST, PATCH or DELETE capability."""
import base64
import json
import os
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, build_opener, HTTPRedirectHandler

from .core import Blocked, authorize, policy, valid_url


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Blocked("redirect_not_allowed")


def get(url, headers=None, limit=8000000):
    try:
        with build_opener(NoRedirect).open(Request(url, headers=headers or {}, method="GET"), timeout=15) as response:
            raw = response.read(limit+1)
            if len(raw) > limit:
                raise Blocked("response_too_large")
            return raw, response.headers.get_content_type()
    except (HTTPError, URLError, TimeoutError, OSError):
        raise Blocked("source_unavailable") from None


def original_image(url):
    if not valid_url(url, policy()["image_hosts"]):
        raise Blocked("invalid_original_image")
    raw, mime = get(url)
    jpeg = raw.startswith(b"\xff\xd8\xff") and mime == "image/jpeg"
    png = raw.startswith(b"\x89PNG\r\n\x1a\n") and mime == "image/png"
    if not (jpeg or png):
        raise Blocked("unsupported_original_image")
    return f'data:{mime};base64,' + base64.b64encode(raw).decode()


class SupabaseReader:
    def __init__(self):
        self.base = 'https://' + policy()["project"] + '.supabase.co/rest/v1/'
        self.key = os.environ.get("KAIYDO_SUPABASE_READ_KEY")
        if not self.key:
            raise Blocked("read_key_missing")

    def rows(self, table, params):
        authorize("read_offers")
        if table not in {"publicacoes", "ofertas", "historico_precos", "instagram_publicacoes"}:
            raise Blocked("table_not_allowed")
        raw, _ = get(self.base + table + '?' + urlencode(params),
                     {"apikey": self.key, "Authorization": "Bearer " + self.key})
        result = json.loads(raw)
        if not isinstance(result, list):
            raise Blocked("invalid_source_response")
        return result

    def candidates(self, limit=20):
        pubs = self.rows("publicacoes", {"canal": "eq.telegram", "situacao": "eq.publicada",
                         "select": "id,oferta_id,canal,situacao,id_mensagem_externa,publicado_em",
                         "order": "id.desc", "limit": min(max(limit, 1), 100)})
        for pub in pubs:
            yield self.evidence(pub)

    def evidence(self, pub):
        offer_id = int(pub["oferta_id"])
        offers = self.rows("ofertas", {"id": f"eq.{offer_id}", "select":
            "id,titulo,moeda,preco_atual,url_afiliado,url_imagem,disponivel,expira_em,codigo_cupom,visto_ultimo_em,hash_conteudo"})
        if len(offers) != 1:
            raise Blocked("offer_missing")
        # Bound size, conservative: an incomplete window may block, never invent evidence.
        history = self.rows("historico_precos", {"oferta_id": f"eq.{offer_id}",
            "select": "id,oferta_id,preco,moeda,disponivel,observado_em", "order": "observado_em.desc", "limit": 1000})
        existing = self.rows("instagram_publicacoes", {"oferta_id": f"eq.{offer_id}", "select": "id", "limit": 1})
        return {"offer": offers[0], "telegram": pub, "history": history, "instagram_exists": bool(existing)}
