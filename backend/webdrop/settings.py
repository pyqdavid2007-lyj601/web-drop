"""Django settings for the web-drop demo (repo/backend)."""

import os
import re
from pathlib import Path

from django.core.exceptions import ImproperlyConfigured

BASE_DIR = Path(__file__).resolve().parent.parent          # repo/backend
REPO_DIR = BASE_DIR.parent                                  # repo/
FRONTEND_BUILD_DIR = REPO_DIR / 'frontend' / 'app_dart' / 'build' / 'web'


# --- repo/.env -------------------------------------------------------------
# KEY=VALUE per line; '#' comments (own line or after the value); real env wins.
# Nothing here is a secret - the app has no authentication (see README).

def _load_dotenv(path):
    try:
        content = path.read_text(encoding='utf-8')
    except OSError:
        return
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, _, value = line.partition('=')
        key = key.strip()
        value = re.split(r'\s+#', value, maxsplit=1)[0].strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def _env_int(name, default, minimum=1):
    """Integer knob from the environment (or repo/.env).

    Fails loudly on a bad value: silently falling back to the default when
    someone writes MAX_UPLOAD_FILE_SIZE_MB=1GiB would be worse than not starting.
    """
    raw = os.environ.get(name)
    if raw is None or raw == '':
        return default
    try:
        value = int(raw)
    except ValueError:
        raise ImproperlyConfigured(
            f'{name} 必须是整数，当前是 {raw!r}（见 repo/.env）')
    return max(minimum, value)


_load_dotenv(REPO_DIR / '.env')

SECRET_KEY = 'dev-only-insecure-key-change-me'
DEBUG = True
ALLOWED_HOSTS = [
    '127.0.0.1',
    'localhost',
    # Cloudflare Quick Tunnel (菜单 3): random https://<name>.trycloudflare.com host; dot = subdomain wildcard.
    '.trycloudflare.com',
    # ngrok (菜单 4): free tier hands out <name>.ngrok-free.dev / .ngrok-free.app hosts.
    '.ngrok-free.dev',
    '.ngrok-free.app',
    '.ngrok.io',
]

if os.environ.get('WEBDROP_ALLOW_ANY_HOST') == '1':
    # 菜单 2 binds the dev server to 0.0.0.0 so phones on the same Wi-Fi can reach it;
    # that needs an open ALLOWED_HOSTS (the app has no authentication anyway).
    ALLOWED_HOSTS = ['*']

# CSRF behind a tunnel: Cloudflare / ngrok terminate TLS in front of this dev server, so
# Django only sees plain HTTP and would reject every POST/PUT/DELETE on Origin mismatch (403).
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')

# Belt and braces for proxies that do not forward the scheme header; the leading dot is
# Django's subdomain wildcard, so a brand-new random Quick Tunnel URL works unedited.
CSRF_TRUSTED_ORIGINS = [
    'https://*.trycloudflare.com',
    'https://*.ngrok-free.dev',
    'https://*.ngrok-free.app',
    'https://*.ngrok.io',
]

# A rejected CSRF request must not answer with Django's HTML 403 page (the JS/Dart client
# cannot parse it); see files.views.csrf_failure.
CSRF_FAILURE_VIEW = 'files.views.csrf_failure'

INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'files',
]

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'webdrop.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [BASE_DIR / 'templates'],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'webdrop.wsgi.application'
ASGI_APPLICATION = 'webdrop.asgi.application'

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': BASE_DIR / 'db.sqlite3',
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
]

LANGUAGE_CODE = 'zh-hans'
TIME_ZONE = 'UTC'
USE_I18N = True
USE_TZ = True

STATIC_URL = 'static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'
# The AngularDart build output is mounted as static files: frontend and API share one origin (no CORS).
STATICFILES_DIRS = [FRONTEND_BUILD_DIR] if FRONTEND_BUILD_DIR.is_dir() else []

MEDIA_ROOT = BASE_DIR / 'media'
MEDIA_URL = 'media/'

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

# Uploads (tunables in repo/.env, see README 配置): small files may go through
# POST /api/files/ in one multipart request; big ones use the chunked endpoints, which also
# work through proxies that cap request bodies (Cloudflare: 100 MB) and let the client
# upload several chunks in parallel. DATA_UPLOAD_MAX_MEMORY_SIZE counts raw bodies (the PUT
# chunks), so it follows the chunk size instead of being a fixed number.
FILE_UPLOAD_MAX_MEMORY_SIZE = 5 * 1024 * 1024
UPLOAD_CHUNK_SIZE = _env_int('UPLOAD_CHUNK_SIZE_MB', 8) * 1024 * 1024
DATA_UPLOAD_MAX_MEMORY_SIZE = UPLOAD_CHUNK_SIZE + 8 * 1024 * 1024
# A file at the limit travels the chunked path and needs ~2x its size on disk while parts merge (1 GiB -> ~2 GiB).
MAX_UPLOAD_FILE_SIZE = _env_int('MAX_UPLOAD_FILE_SIZE_MB', 1024) * 1024 * 1024
