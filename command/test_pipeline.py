import json
import unittest
from pathlib import Path
from unittest.mock import patch

from .core import Blocked, default_brand, logo_asset
from .pipeline import cycle, export_bundle
from . import test_command as fixtures
evidence = fixtures.evidence


class PipelineTests(unittest.TestCase):
    setUp = fixtures.CommandTests.setUp
    tearDown = fixtures.CommandTests.tearDown
    ready = fixtures.CommandTests.ready
    def test_cycle_generates_bundle_and_repeat_does_not_download_or_render(self):
        data = evidence()
        renderer = lambda svg: b'\xff\xd8\xfftest'
        first = cycle(self.store, [data], self.path/'review', renderer=renderer,
                      image_loader=lambda _: 'data:image/png;base64,test')
        self.assertEqual(len(first['prepared']), 1)
        self.assertFalse(first['published'])
        def fail(_):
            raise AssertionError('must not repeat IO')
        second = cycle(self.store, [data], self.path/'review', renderer=fail, image_loader=fail)
        self.assertTrue(second['prepared'][0]['existing'])
        self.assertEqual(first['prepared'][0]['artifact_hash'], second['prepared'][0]['artifact_hash'])

    def test_below_threshold_is_blocked_without_image_download(self):
        data = evidence()
        data['history'][0]['preco'] = '71.00'
        result = cycle(self.store, [data], self.path/'review')
        self.assertEqual(result['blocked'][0]['code'], 'below_preparation_discount_threshold')
        self.assertEqual(len(result['prepared']), 0)

    def test_duplicate_offer_does_not_create_second_task(self):
        data = evidence()
        result = cycle(self.store, [data, data], self.path/'review', limit=2,
                       renderer=lambda _: b'\xff\xd8\xfftest', image_loader=lambda _: 'data:image/png;base64,test')
        self.assertEqual(len(result['prepared']), 1)

    def test_tampered_export_is_blocked(self):
        task, row = self.ready()
        result = export_bundle(self.store, task, self.path/'review', lambda _: b'\xff\xd8\xfftest')
        (Path(result['folder'])/'oferta.jpg').write_bytes(b'tampered')
        with self.assertRaises(Blocked):
            export_bundle(self.store, task, self.path/'review')

    def test_caption_preserves_title_and_url_and_art_has_discreet_footer(self):
        data = evidence()
        data['offer']['titulo'] = 'Produto 2.0'
        task, row = self.ready(data)
        result = json.loads(row['result'])
        self.assertIn('Produto 2.0', result['draft']['legenda'])
        self.assertIn('R$ 70,00', result['draft']['legenda'])
        self.assertIn(data['offer']['url_afiliado'], result['draft']['legenda'])
        self.assertIn('Publicidade • link de afiliado', result['draft']['legenda'])
        self.assertNotIn('PUBLICIDADE', result['svg'])


if __name__ == '__main__':
    unittest.main()
