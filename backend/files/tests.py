import io
import json
import os
import tempfile
from datetime import timedelta
from pathlib import Path

from django.core.exceptions import ImproperlyConfigured
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import Client, SimpleTestCase, TestCase, override_settings
from django.utils import timezone

from webdrop.settings import _env_int, _load_dotenv

from .models import StoredFile, UploadSession

TMP_MEDIA = tempfile.mkdtemp(prefix='webdrop-test-')


@override_settings(MEDIA_ROOT=TMP_MEDIA)
class FileTransferApiTests(TestCase):
    def setUp(self):
        self.client = Client(enforce_csrf_checks=True)
        self.client.get('/')  # sets the csrftoken cookie

    def csrf(self):
        return self.client.cookies['csrftoken'].value

    def upload(self, name='hello.txt', content=b'hello web-drop', **extra):
        payload = b'--BOUNDARY\r\n'
        payload += b'Content-Disposition: form-data; name="file"; filename="' + name.encode() + b'"\r\n'
        payload += b'Content-Type: text/plain\r\n\r\n' + content + b'\r\n--BOUNDARY--\r\n'
        return self.client.post(
            '/api/files/', data=payload,
            content_type='multipart/form-data; boundary=BOUNDARY',
            HTTP_X_CSRFTOKEN=self.csrf(), **extra)

    def test_index_sets_csrf_cookie(self):
        response = self.client.get('/')
        self.assertEqual(response.status_code, 200)
        self.assertIn('csrftoken', response.cookies)

    def test_health(self):
        self.assertEqual(self.client.get('/api/health/').json(), {'ok': True})

    def test_upload_without_csrf_is_rejected(self):
        response = self.client.post(
            '/api/files/',
            data={'file': SimpleUploadedFile('x.txt', b'x', content_type='text/plain')})
        self.assertEqual(response.status_code, 403)

    def test_upload_through_tunnel_origin_is_accepted(self):
        """Cloudflare/ngrok terminate TLS in front of the dev server, so Django
        sees http:// while the browser sends Origin: https://<tunnel host>."""
        response = self.upload(
            HTTP_ORIGIN='https://demo.trycloudflare.com',
            HTTP_X_FORWARDED_PROTO='https')
        self.assertEqual(response.status_code, 201)

    @override_settings(DEBUG=True)
    def test_upload_from_unknown_origin_is_rejected_with_json(self):
        response = self.upload(HTTP_ORIGIN='https://evil.example.com')
        self.assertEqual(response.status_code, 403)
        body = response.json()
        self.assertIn('Origin', body['error'])
        self.assertIn('Origin checking failed', body['detail'])

    def test_upload_list_download_delete_roundtrip(self):
        response = self.upload(content=b'hello web-drop')
        self.assertEqual(response.status_code, 201)
        body = response.json()['file']
        self.assertEqual(body['name'], 'hello.txt')
        self.assertEqual(body['size'], len(b'hello web-drop'))
        self.assertEqual(StoredFile.objects.count(), 1)
        self.assertTrue(StoredFile.objects.get().path.exists())

        listing = self.client.get('/api/files/').json()['files']
        self.assertEqual([f['name'] for f in listing], ['hello.txt'])

        download = self.client.get(body['download_url'])
        self.assertEqual(download.status_code, 200)
        self.assertEqual(b''.join(download.streaming_content), b'hello web-drop')
        self.assertIn('attachment', download['Content-Disposition'])
        self.assertIn('hello.txt', download['Content-Disposition'])

        deleted = self.client.delete('/api/files/%s/' % body['id'], HTTP_X_CSRFTOKEN=self.csrf())
        self.assertEqual(deleted.status_code, 200)
        self.assertEqual(StoredFile.objects.count(), 0)

    @override_settings(MAX_UPLOAD_FILE_SIZE=10)
    def test_oversize_upload_is_rejected(self):
        response = self.upload(content=b'x' * 64)
        self.assertEqual(response.status_code, 413)
        self.assertEqual(StoredFile.objects.count(), 0)

    def test_upload_without_file_field(self):
        response = self.client.post('/api/files/', data={}, HTTP_X_CSRFTOKEN=self.csrf())
        self.assertEqual(response.status_code, 400)

    def test_missing_file_is_404(self):
        response = self.client.get('/api/files/00000000-0000-0000-0000-000000000000/')
        self.assertEqual(response.status_code, 404)


class DotenvSettingsTests(SimpleTestCase):
    """repo/.env is what feeds the size knobs in webdrop.settings."""

    def write_env(self, text):
        path = Path(TMP_MEDIA) / 'dotenv-test.env'
        path.write_text(text, encoding='utf-8')
        return path

    def test_values_are_parsed_and_real_environment_wins(self):
        os.environ['WEBDROP_TEST_EXISTING'] = 'from-env'
        try:
            _load_dotenv(self.write_env(
                '# a comment\n'
                'WEBDROP_TEST_SIZE=42   # inline comment still works\n'
                'WEBDROP_TEST_QUOTED="hello world"\n'
                'not a key-value line\n'
                'WEBDROP_TEST_EXISTING=from-file\n'))
            self.assertEqual(os.environ['WEBDROP_TEST_SIZE'], '42')
            self.assertEqual(os.environ['WEBDROP_TEST_QUOTED'], 'hello world')
            self.assertEqual(os.environ['WEBDROP_TEST_EXISTING'], 'from-env')
        finally:
            for key in ('WEBDROP_TEST_SIZE', 'WEBDROP_TEST_QUOTED',
                        'WEBDROP_TEST_EXISTING'):
                os.environ.pop(key, None)

    def test_missing_file_and_defaults_are_harmless(self):
        _load_dotenv(Path(TMP_MEDIA) / 'does-not-exist.env')
        self.assertEqual(_env_int('WEBDROP_TEST_MISSING', 1024), 1024)

    def test_bad_value_fails_loudly(self):
        os.environ['WEBDROP_TEST_BAD'] = '1GiB'
        try:
            with self.assertRaises(ImproperlyConfigured):
                _env_int('WEBDROP_TEST_BAD', 1024)
        finally:
            del os.environ['WEBDROP_TEST_BAD']

    def test_size_settings_stay_consistent_whatever_env_says(self):
        """Whatever repo/.env asks for, the values must stay usable: whole MB and
        a chunk that still fits in DATA_UPLOAD_MAX_MEMORY_SIZE."""
        from django.conf import settings

        for value in (settings.MAX_UPLOAD_FILE_SIZE, settings.UPLOAD_CHUNK_SIZE):
            self.assertGreaterEqual(value, 1024 * 1024)
            self.assertEqual(value % (1024 * 1024), 0)
        self.assertGreater(settings.DATA_UPLOAD_MAX_MEMORY_SIZE,
                           settings.UPLOAD_CHUNK_SIZE)


@override_settings(MEDIA_ROOT=TMP_MEDIA, UPLOAD_CHUNK_SIZE=4)
class ChunkedUploadTests(TestCase):
    """The chunked path exists because proxies cap one request body (Cloudflare
    free plan: 100 MB) and because parallel chunks are faster on slow links."""

    def setUp(self):
        self.client = Client(enforce_csrf_checks=True)
        self.client.get('/')  # sets the csrftoken cookie

    def csrf(self):
        return self.client.cookies['csrftoken'].value

    def init(self, name='big.bin', size=10, content_type='application/octet-stream'):
        return self.client.post(
            '/api/uploads/',
            data=json.dumps({'name': name, 'size': size, 'content_type': content_type}),
            content_type='application/json', HTTP_X_CSRFTOKEN=self.csrf())

    def put(self, upload_id, index, data, token=True):
        return self.client.put(
            '/api/uploads/%s/%s/' % (upload_id, index), data=data,
            content_type='application/octet-stream',
            **({'HTTP_X_CSRFTOKEN': self.csrf()} if token else {}))

    def complete(self, upload_id):
        return self.client.post(
            '/api/uploads/%s/complete/' % upload_id, HTTP_X_CSRFTOKEN=self.csrf())

    def test_roundtrip(self):
        started = self.init(size=10)
        self.assertEqual(started.status_code, 201)
        plan = started.json()
        self.assertEqual(plan['chunk_size'], 4)
        self.assertEqual(plan['chunk_count'], 3)
        upload_id = plan['upload_id']

        self.assertEqual(self.put(upload_id, 0, b'abcd').status_code, 200)
        self.assertEqual(self.put(upload_id, 1, b'efgh').status_code, 200)
        self.assertEqual(self.put(upload_id, 2, b'ij').status_code, 200)

        done = self.complete(upload_id)
        self.assertEqual(done.status_code, 201)
        stored = done.json()['file']
        self.assertEqual(stored['name'], 'big.bin')
        self.assertEqual(stored['size'], 10)

        download = self.client.get(stored['download_url'])
        self.assertEqual(b''.join(download.streaming_content), b'abcdefghij')

        # session + its temp dir are gone, the file is a normal StoredFile
        self.assertEqual(UploadSession.objects.count(), 0)
        self.assertEqual(StoredFile.objects.count(), 1)
        self.assertFalse((Path(TMP_MEDIA) / 'tmp' / upload_id).exists())

    def test_wrong_chunk_size_is_rejected(self):
        upload_id = self.init(size=10).json()['upload_id']
        response = self.put(upload_id, 0, b'abc')  # expected 4 bytes
        self.assertEqual(response.status_code, 400)

    def test_chunk_index_out_of_range(self):
        upload_id = self.init(size=10).json()['upload_id']
        self.assertEqual(self.put(upload_id, 3, b'abcd').status_code, 400)

    def test_complete_with_missing_chunk(self):
        upload_id = self.init(size=10).json()['upload_id']
        self.put(upload_id, 0, b'abcd')
        response = self.complete(upload_id)
        self.assertEqual(response.status_code, 400)
        self.assertIn('1', response.json()['error'])  # mentions the missing index
        self.assertEqual(StoredFile.objects.count(), 0)

    def test_abort_removes_session_and_chunks(self):
        upload_id = self.init(size=10).json()['upload_id']
        self.put(upload_id, 0, b'abcd')
        aborted = self.client.delete(
            '/api/uploads/%s/' % upload_id, HTTP_X_CSRFTOKEN=self.csrf())
        self.assertEqual(aborted.status_code, 200)
        self.assertEqual(UploadSession.objects.count(), 0)
        self.assertFalse((Path(TMP_MEDIA) / 'tmp' / upload_id).exists())

    @override_settings(MAX_UPLOAD_FILE_SIZE=8)
    def test_init_over_the_limit_is_413(self):
        response = self.init(size=9)
        self.assertEqual(response.status_code, 413)
        self.assertEqual(UploadSession.objects.count(), 0)

    def test_chunk_put_requires_csrf(self):
        upload_id = self.init(size=10).json()['upload_id']
        self.assertEqual(self.put(upload_id, 0, b'abcd', token=False).status_code, 403)

    def test_stale_sessions_are_swept_on_init(self):
        stale = UploadSession.objects.create(
            original_name='old.bin', content_type='', total_size=4, chunk_size=4)
        stale.dir.mkdir(parents=True, exist_ok=True)
        (stale.dir / '0.part').write_bytes(b'abcd')
        UploadSession.objects.filter(pk=stale.pk).update(
            created_at=timezone.now() - timedelta(days=2))

        self.init(size=4)  # any new session sweeps the abandoned ones

        self.assertFalse(UploadSession.objects.filter(pk=stale.pk).exists())
        self.assertFalse(stale.dir.exists())
