"""Finite preparation cycle. All outputs are local; never publishes or writes remotely."""
import hashlib
import io
import json
import time
from pathlib import Path

from .core import Blocked, canonical, default_brand, digest, policy, process_one, validate
from .source import original_image


def jpeg_bytes(svg):
    try:
        import resvg_py
        from PIL import Image
    except ImportError:
        raise Blocked('renderer_not_installed') from None
    png = resvg_py.svg_to_bytes(svg_string=svg)
    image = Image.open(io.BytesIO(png)).convert('RGB')
    if image.size != (1080, 1350):
        raise Blocked('unexpected_image_size')
    target = io.BytesIO()
    image.save(target, format='JPEG', quality=95, subsampling=0)
    return target.getvalue()


def export_bundle(store, task, root, renderer=jpeg_bytes):
    row = store.db.execute("SELECT * FROM tasks WHERE id=? AND state='ready'", (task,)).fetchone()
    if not row:
        raise Blocked('not_ready')
    result = json.loads(row['result'])
    if result['valid_until'] <= time.time() or result['policy_hash'] != digest(policy()):
        raise Blocked('artifact_expired_or_policy_changed')
    folder = Path(root).resolve() / str(task) / row['result_hash']
    manifest_file = folder / 'review.json'
    if manifest_file.exists():
        old = json.loads(manifest_file.read_text(encoding='utf-8'))
        if old.get('artifact_hash') != row['result_hash']:
            raise Blocked('export_integrity_failed')
        for name, sha in old['files'].items():
            if name not in {'oferta.jpg', 'preview.svg', 'legenda.txt'}:
                raise Blocked('export_integrity_failed')
            if hashlib.sha256((folder/name).read_bytes()).hexdigest() != sha:
                raise Blocked('export_integrity_failed')
        return old | {'folder': str(folder), 'existing': True}
    raw = renderer(result['svg'])
    if not raw.startswith(b'\xff\xd8\xff'):
        raise Blocked('renderer_invalid_jpeg')
    files = {'oferta.jpg': raw, 'preview.svg': result['svg'].encode(),
             'legenda.txt': result['draft']['legenda'].encode()}
    review = {'task': task, 'artifact_hash': row['result_hash'], 'offer': result['draft']['oferta_id'],
              'valid_until': result['valid_until'], 'state': 'awaiting_review', 'published': False,
              'files': {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}}
    folder.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        temp = folder / (name+'.tmp')
        temp.write_bytes(data)
        temp.replace(folder/name)
    # Manifest last: a crash before it can be recovered by regenerating the bundle.
    temp = folder/'review.json.tmp'
    temp.write_text(canonical(review), encoding='utf-8')
    temp.replace(manifest_file)
    with store.tx():
        store.event(task, 'review_bundle_ready', {'jpeg_sha256': review['files']['oferta.jpg']}, 'success')
    return review | {'folder': str(folder), 'existing': False}


def cycle(store, candidates, output, limit=1, renderer=jpeg_bytes, image_loader=original_image):
    if not 1 <= limit <= 20:
        raise Blocked('invalid_cycle_limit')
    report = {'mode': 'local_preparation_only', 'published': False, 'prepared': [], 'blocked': []}
    seen = set()
    selected = []
    # Validate all bounded input before ordering; repeat versions of an offer cannot fill the batch.
    for data in list(candidates)[:100]:
        offer_id = data['offer']['id']
        if offer_id in seen:
            continue
        seen.add(offer_id)
        try:
            draft = validate(data)
            if int(draft['desconto_percentual']) < policy()['preparation_min_discount_percent']:
                raise Blocked('below_preparation_discount_threshold')
            selected.append((int(draft['desconto_percentual']), data))
        except Blocked as exc:
            report['blocked'].append({'offer': offer_id, 'code': str(exc)})
    selected.sort(key=lambda item: item[0], reverse=True)
    logo, sha = default_brand()
    for _, data in selected[:limit]:
        task = store.enqueue(data)
        process_one(store, logo, sha, image_loader, task=task)
        try:
            report['prepared'].append(export_bundle(store, task, output, renderer))
        except Blocked as exc:
            state = store.db.execute('SELECT reason FROM tasks WHERE id=?', (task,)).fetchone()
            code = state['reason'] if str(exc) == 'not_ready' and state['reason'] else str(exc)
            report['blocked'].append({'offer': data['offer']['id'], 'code': code})
        except Exception:
            report['blocked'].append({'offer': data['offer']['id'], 'code': 'render_or_export_failed'})
    with store.tx():
        store.event(None, 'preparation_cycle_finished',
                    {'prepared': len(report['prepared']), 'blocked': report['blocked']},
                    'success' if report['prepared'] else 'blocked')
    return report
