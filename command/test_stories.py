import json
import unittest
from xml.etree import ElementTree

from . import test_command as fixtures
from .core import Blocked
from .pipeline import export_bundle
from .stories import handoff, readiness, story_svg


class StoryTests(unittest.TestCase):
    setUp = fixtures.CommandTests.setUp
    tearDown = fixtures.CommandTests.tearDown
    ready = fixtures.CommandTests.ready

    def test_vertical_size_and_safe_layout(self):
        _, row = self.ready()
        svg = story_svg(json.loads(row['result']))
        root = ElementTree.fromstring(svg)
        self.assertEqual(root.get('height'), '1920')
        self.assertEqual(root.get('width'), '1080')
        self.assertNotIn('Ver oferta', svg)
        self.assertIn('Ver oferta', story_svg(json.loads(row['result']), preview=True))

    def test_native_link_exact_and_no_auto_schedule(self):
        _, row = self.ready()
        result = json.loads(row['result'])
        markup, contract = handoff(result, b'\xff\xd8\xfftest')
        self.assertIn('<insta-link url="https://meli.la/abcd"', markup)
        self.assertTrue(contract['native_link_required'])
        self.assertFalse(contract['published'])
        self.assertNotIn('storyPostUuid', contract)
        self.assertNotIn('date', contract)

    def test_story_title_escaped_and_affiliate_revalidated(self):
        _, row = self.ready()
        result = json.loads(row['result'])
        result['draft']['titulo'] = '<script>alert(1)</script>'
        self.assertNotIn('<script>', story_svg(result))
        result['draft']['url_afiliado'] = 'https://evil.test/offer'
        with self.assertRaises(Blocked):
            story_svg(result)
        with self.assertRaises(Blocked):
            handoff(result, b'\xff\xd8\xfftest')

    def test_bundle_contains_both_formats(self):
        task, row = self.ready()
        bundle = export_bundle(self.store, task, self.path/'review', lambda _: b'\xff\xd8\xfftest')
        self.assertIn('story.jpg', bundle['files'])
        self.assertIn('story.html', bundle['files'])
        self.assertIn('oferta.jpg', bundle['files'])

    def test_configuration_inspection_never_claims_connection_or_reveals_secret(self):
        config = readiness({'KAIYDO_STORRITO_ORIGIN': 'https://12345678-1234-1234-1234-123456789abc.storrito.com',
                            'KAIYDO_STORRITO_TOKEN': 'secret-token', 'KAIYDO_INSTAGRAM_USERNAME': '_baixoupromocoes_'})
        self.assertTrue(config['origin_configured'])
        self.assertFalse(config['connection_verified'])
        self.assertFalse(config['publishing_enabled'])
        self.assertNotIn('secret-token', json.dumps(config))
        self.assertFalse(readiness({'KAIYDO_STORRITO_ORIGIN':'https://storrito.com.evil.test'})['origin_configured'])


if __name__ == '__main__':
    unittest.main()
