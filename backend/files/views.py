import shutil
import uuid
from datetime import timedelta
from pathlib import Path

from django.conf import settings
from django.http import FileResponse, JsonResponse
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.csrf import ensure_csrf_cookie
from django.views.decorators.http import require_http_methods

from .models import StoredFile, UploadSession


def _safe_name(name: str) -> str:
    """Never trust the client name for the on-disk path: keep basename + ext."""
    return (name or '').replace('\\', '/').split('/')[-1][:255]


def _json_error(message: str, status: int) -> JsonResponse:
    return JsonResponse({'error': message}, status=status)


def csrf_failure(request, reason=''):
    """Answer CSRF rejections with JSON instead of Django's HTML 403 page.

    The client shows whatever the API returns, so a rejected request should
    explain itself: "uploads fail with 403 the moment they start" is almost
    always the Origin check complaining about a proxy that terminates TLS
    (see SECURE_PROXY_SSL_HEADER / CSRF_TRUSTED_ORIGINS in settings).
    """
    hint = 'CSRF 校验失败，请刷新页面后重试'
    if 'Origin checking failed' in reason:
        hint = '请求来源（Origin）未被信任：隧道/域名访问请刷新页面；换过地址就用新地址重新打开'
    elif 'CSRF cookie not set' in reason:
        hint = '浏览器没拿到 csrftoken cookie，请刷新页面后重试'
    elif 'Referer checking failed' in reason:
        hint = '来源校验失败（Referer）：请始终用同一个地址访问，别混用 http/https'
    payload = {'error': hint}
    if settings.DEBUG:
        payload['detail'] = reason
    return JsonResponse(payload, status=403)


@ensure_csrf_cookie
def index(request):
    """Serve the AngularDart app shell; sets the csrftoken cookie."""
    return render(request, 'index.html')


def health(request):
    return JsonResponse({'ok': True})


@ensure_csrf_cookie
@require_http_methods(['GET', 'POST'])
def file_collection(request):
    if request.method == 'GET':
        return JsonResponse({'files': [f.to_json() for f in StoredFile.objects.all()]})

    upload = request.FILES.get('file')
    if upload is None:
        return _json_error('缺少 multipart 字段 file', 400)
    if upload.size > settings.MAX_UPLOAD_FILE_SIZE:
        return _json_error(f'文件超过上限 {settings.MAX_UPLOAD_FILE_SIZE} 字节', 413)

    display_name = _safe_name(upload.name)
    suffix = Path(display_name).suffix[:32]
    stored_name = uuid.uuid4().hex + suffix
    dest_dir = Path(settings.MEDIA_ROOT) / 'uploads'
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / stored_name
    with dest.open('wb') as out:
        for chunk in upload.chunks():
            out.write(chunk)

    record = StoredFile.objects.create(
        original_name=display_name or stored_name,
        size=dest.stat().st_size,
        content_type=(upload.content_type or '')[:255],
        stored_name=stored_name,
    )
    return JsonResponse({'file': record.to_json()}, status=201)


# --- chunked uploads -------------------------------------------------------
#
# Cloudflare (and most proxies) cap a single request body (100 MB), which is why big files
# are split; chunks also let the client run several connections in parallel (~2.3x measured).

def _sweep_stale_sessions() -> None:
    """Drop sessions (and their chunk dirs) abandoned more than a day ago."""
    cutoff = timezone.now() - timedelta(days=1)
    for stale in UploadSession.objects.filter(created_at__lt=cutoff):
        shutil.rmtree(stale.dir, ignore_errors=True)
        stale.delete()


@require_http_methods(['POST'])
def upload_init(request):
    import json

    try:
        payload = json.loads(request.body or b'{}')
    except ValueError:
        return _json_error('请求体不是合法 JSON', 400)

    name = _safe_name(payload.get('name') or '')
    try:
        total_size = int(payload.get('size') or 0)
    except (TypeError, ValueError):
        return _json_error('size 必须是整数', 400)

    if total_size <= 0:
        return _json_error('size 必须大于 0', 400)
    if total_size > settings.MAX_UPLOAD_FILE_SIZE:
        return _json_error(
            f'文件超过上限 {settings.MAX_UPLOAD_FILE_SIZE} 字节', 413)

    _sweep_stale_sessions()

    session = UploadSession.objects.create(
        original_name=name or 'unnamed',
        content_type=(payload.get('content_type') or '')[:255],
        total_size=total_size,
        chunk_size=settings.UPLOAD_CHUNK_SIZE,
    )
    session.dir.mkdir(parents=True, exist_ok=True)
    return JsonResponse({
        'upload_id': str(session.id),
        'chunk_size': session.chunk_size,
        'chunk_count': session.chunk_count,
    }, status=201)


def _get_session(upload_id):
    try:
        return UploadSession.objects.get(pk=upload_id), None
    except (UploadSession.DoesNotExist, ValueError):
        return None, _json_error('上传会话不存在', 404)


@require_http_methods(['PUT'])
def upload_chunk(request, upload_id, index):
    session, error = _get_session(upload_id)
    if error is not None:
        return error

    if index < 0 or index >= session.chunk_count:
        return _json_error(f'分片序号越界（0..{session.chunk_count - 1}）', 400)

    data = request.body
    expected = session.expected_chunk_size(index)
    if len(data) != expected:
        return _json_error(f'分片大小不符：期望 {expected} 字节，收到 {len(data)}', 400)

    session.dir.mkdir(parents=True, exist_ok=True)
    target = session.dir / f'{index}.part'
    temp = session.dir / f'{index}.part.tmp'
    with temp.open('wb') as out:
        out.write(data)
    temp.replace(target)
    return JsonResponse({'received': index}, status=200)


@require_http_methods(['DELETE'])
def upload_abort(request, upload_id):
    """Client gives up on a chunked upload: drop the session and its chunks."""
    session, error = _get_session(upload_id)
    if error is not None:
        return error
    shutil.rmtree(session.dir, ignore_errors=True)
    session.delete()
    return JsonResponse({'aborted': True}, status=200)


@require_http_methods(['POST'])
def upload_complete(request, upload_id):
    session, error = _get_session(upload_id)
    if error is not None:
        return error

    missing = [i for i in range(session.chunk_count)
               if not (session.dir / f'{i}.part').exists()]
    if missing:
        preview = ', '.join(str(i) for i in missing[:10])
        return _json_error(f'还有分片未上传：{preview}', 400)

    total = sum((session.dir / f'{i}.part').stat().st_size
                for i in range(session.chunk_count))
    if total != session.total_size:
        return _json_error(f'分片总大小 {total} != 声明大小 {session.total_size}', 400)

    suffix = Path(session.original_name).suffix[:32]
    stored_name = uuid.uuid4().hex + suffix
    dest_dir = Path(settings.MEDIA_ROOT) / 'uploads'
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / stored_name
    with dest.open('wb') as out:
        for i in range(session.chunk_count):
            with (session.dir / f'{i}.part').open('rb') as part:
                shutil.copyfileobj(part, out, 1024 * 1024)

    record = StoredFile.objects.create(
        original_name=session.original_name,
        size=dest.stat().st_size,
        content_type=session.content_type,
        stored_name=stored_name,
    )
    shutil.rmtree(session.dir, ignore_errors=True)
    session.delete()
    return JsonResponse({'file': record.to_json()}, status=201)


def _get_or_404(file_id):
    try:
        return StoredFile.objects.get(pk=file_id), None
    except StoredFile.DoesNotExist:
        return None, _json_error('文件不存在', 404)


@require_http_methods(['GET', 'DELETE'])
def file_detail(request, file_id):
    record, error = _get_or_404(file_id)
    if error is not None:
        return error
    if request.method == 'DELETE':
        path = record.path
        if path.exists():
            path.unlink()
        record.delete()
        return JsonResponse({'deleted': True, 'id': str(file_id)})
    return JsonResponse({'file': record.to_json()})


@require_http_methods(['GET'])
def file_download(request, file_id):
    record, error = _get_or_404(file_id)
    if error is not None:
        return error
    path = record.path
    if not path.exists():
        return _json_error('文件已不在磁盘上', 410)
    response = FileResponse(
        path.open('rb'),
        as_attachment=True,
        filename=record.original_name,
        content_type=record.content_type or 'application/octet-stream',
    )
    response['Content-Length'] = str(path.stat().st_size)
    return response
