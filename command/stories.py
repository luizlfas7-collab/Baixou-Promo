"""Story media and native-link handoff, without provider calls or publishing."""
import base64
import html
import json
import re
import textwrap
from decimal import Decimal
from urllib.parse import urlsplit
from xml.etree import ElementTree

from .core import Blocked, digest, policy, valid_url


def story_svg(result, preview=False):
    d = result['draft']
    if not valid_url(d['url_afiliado'], policy()['affiliate_hosts']):
        raise Blocked('invalid_story_affiliate')
    images = ElementTree.fromstring(result['svg']).findall('{http://www.w3.org/2000/svg}image')
    if len(images) != 2 or any(not x.get('href', '').startswith('data:image/') for x in images):
        raise Blocked('missing_original_story_assets')
    logo, product = [html.escape(x.get('href'), quote=True) for x in images]
    title = textwrap.wrap(d['titulo'], width=52, break_long_words=True)
    lines = ''.join(f'<tspan x="60" dy="32">{html.escape(x)}</tspan>' for x in title)
    before = format(Decimal(d['preco_anterior_observado']), '.2f').replace('.', ',')
    current = format(Decimal(d['preco_atual']), '.2f').replace('.', ',')
    # The native sticker is supplied separately by the provider. A JPEG cannot contain a clickable link.
    sticker_preview = ('<rect x="280" y="1430" width="520" height="120" rx="26" fill="white"/>'
                       '<text x="540" y="1505" text-anchor="middle" font-family="Arial" font-size="42" fill="black">Ver oferta</text>') if preview else ''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1920" viewBox="0 0 1080 1920">
<rect width="1080" height="1920" fill="#080808"/>
<image href="{logo}" x="60" y="260" width="680" height="180" preserveAspectRatio="xMinYMid meet"/>
<rect x="60" y="460" width="960" height="570" fill="white"/>
<image href="{product}" x="70" y="470" width="940" height="550" preserveAspectRatio="xMidYMid meet"/>
<text y="1050" fill="#fff5e2" font-family="Arial" font-size="28">{lines}</text>
<rect x="0" y="1250" width="1080" height="150" fill="#ff7900"/>
<text x="60" y="1295" font-family="Arial" font-size="28">Anterior observado: R$ {before}</text>
<text x="60" y="1365" font-family="Arial" font-size="58">Agora R$ {current}</text>
{sticker_preview}
<text x="540" y="1590" text-anchor="middle" font-family="Arial" font-size="23" fill="#fff5e2">Publicidade • link de afiliado • Preço e estoque sujeitos a alteração</text>
</svg>'''


def handoff(result, background_jpeg):
    d = result['draft']
    if not valid_url(d['url_afiliado'], policy()['affiliate_hosts']):
        raise Blocked('invalid_story_affiliate')
    if not background_jpeg.startswith(b'\xff\xd8\xff'):
        raise Blocked('invalid_story_jpeg')
    image = 'data:image/jpeg;base64,' + base64.b64encode(background_jpeg).decode()
    link = html.escape(d['url_afiliado'], quote=True)
    markup = (f'<insta-story><img src="{image}" style="position:absolute;inset:0;width:1080px;height:1920px">'
              '<div style="position:absolute;left:60px;right:60px;top:1400px;display:flex;justify-content:center">'
              f'<insta-link url="{link}" text="Ver oferta" design="default"></insta-link>'
              '</div></insta-story>')
    contract = {'version': 1, 'format': 'story', 'offer': d['oferta_id'],
                'affiliate_url': d['url_afiliado'], 'native_link_required': True,
                'link_text': 'Ver oferta', 'provider': 'storrito',
                'state': 'awaiting_connection_and_review', 'published': False,
                'artifact_hash': digest(result), 'valid_until': result['valid_until'],
                'html_sha256': __import__('hashlib').sha256(markup.encode()).hexdigest(),
                'warning': 'HTML is a local template, not an API call. Scheduling may publish; do not send without approval.'}
    return markup, contract


def readiness(env):
    """Inspect local configuration only, without revealing values or contacting a service."""
    origin = env.get('KAIYDO_STORRITO_ORIGIN', '')
    try:
        u = urlsplit(origin)
        valid = bool(u.scheme == 'https' and re.fullmatch(r'[a-f0-9-]{36}\.storrito\.com', u.hostname or '')
                     and not u.username and not u.password and not u.port and u.path in ('', '/') and not u.query and not u.fragment)
    except ValueError:
        valid = False
    return {'origin_configured': valid, 'token_configured': bool(env.get('KAIYDO_STORRITO_TOKEN')),
            'account_configured': bool(re.fullmatch(r'[\w.]{1,30}', env.get('KAIYDO_INSTAGRAM_USERNAME', ''))),
            'connection_verified': False, 'publishing_enabled': False}
