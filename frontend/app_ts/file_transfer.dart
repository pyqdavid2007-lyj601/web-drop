// Hand-written Dart side of the file_transfer facade (see file_transfer.d.ts
// for the TypeScript-side contract).
//
// This is the only implementation. app_ts/file_transfer.d.ts declares the same
// types and functions for the TypeScript side (so the generated component still
// type-checks); the Dart build copies this file verbatim into app_dart/lib/.
//
// Note the two worlds differ in ways no transpiler can paper over:
//   * JS browser APIs are lowercase (xhr.onload, form.append)
//   * Dart DOM APIs are camelCase (xhr.onLoad, form.appendBlob)
//   * Dart has no implicit number <-> string coercion, no untyped truthiness
//     and no null leaking into non-nullable types
// Keeping that in one facade module is the whole point of the pattern.
//
// Upload strategy
//   * up to 8 MiB  -> one plain multipart POST (POST /api/files/)
//   * bigger       -> chunked: POST /api/uploads/ then PUT the chunks with
//                     three connections in parallel, then .../complete/
// Why chunked:
//   * proxies cap one request body (Cloudflare free plan: 100 MB -> HTTP 413
//     at the very end of an upload; the chunk size here is 8 MiB)
//   * parallel connections measured ~2.3x on a Quick Tunnel
//     (single 64 MB stream 0.56 MB/s vs 1.27 MB/s with four connections)

import 'dart:async';
import 'dart:convert';
import 'dart:html';

class FileInfo {
  final String id;
  final String name;
  final String sizeLabel;
  final String uploadedAt;
  final String downloadUrl;

  FileInfo(this.id, this.name, this.sizeLabel, this.uploadedAt, this.downloadUrl);
}

abstract class TransferHost {
  num uploadStarted(String name, num size);
  void uploadProgress(num id, num percent, String speed);
  void uploadFinished(num id, bool ok, String message);
  void clearFiles();
  void addFile(FileInfo info);
  void setError(String message);
  void setBusy(bool busy);
}

const String _filesApi = '/api/files/';
const String _uploadsApi = '/api/uploads/';
const int _singleShotLimit = 8 * 1024 * 1024;
const int _maxParallelChunks = 3;

String _csrfToken() {
  final raw = document.cookie;
  if (raw == null) return '';
  for (final part in raw.split(';')) {
    final trimmed = part.trim();
    if (trimmed.startsWith('csrftoken=')) {
      return trimmed.substring('csrftoken='.length);
    }
  }
  return '';
}

String _formatSize(num bytes) {
  if (bytes < 1024) return '${bytes.toInt()} B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}

String _formatTime(String iso) {
  final at = DateTime.tryParse(iso);
  if (at == null) return iso;
  final local = at.toLocal();
  String two(int value) => value < 10 ? '0$value' : '$value';
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _formatSpeed(num bytes, double seconds) {
  if (seconds < 0.3 || bytes <= 0) return '';
  final perSecond = bytes / seconds;
  if (perSecond < 1024) return perSecond.toStringAsFixed(0) + ' B/s';
  if (perSecond < 1024 * 1024) return (perSecond / 1024).toStringAsFixed(0) + ' KB/s';
  return (perSecond / (1024 * 1024)).toStringAsFixed(1) + ' MB/s';
}

FileInfo _fileInfoFromJson(Map<String, dynamic> json) {
  return FileInfo(
    json['id'] as String,
    json['name'] as String,
    _formatSize((json['size'] as num?) ?? 0),
    _formatTime(json['created_at'] as String),
    json['download_url'] as String,
  );
}

void preventDefault(dynamic event) {
  final typed = event as Event?;
  typed?.preventDefault();
}

/// Small request helper for JSON bodies (init/complete/abort). Throws a String
/// with the server's error message when the status code is not 2xx.
Future<Object?> _request(String method, String url, {Object? body, String? contentType}) {
  final xhr = HttpRequest();
  final completer = Completer<Object?>();
  xhr.open(method, url);
  xhr.setRequestHeader('X-CSRFToken', _csrfToken());
  xhr.setRequestHeader('Accept', 'application/json');
  if (contentType != null) {
    xhr.setRequestHeader('Content-Type', contentType);
  }
  xhr.onLoad.listen((_) {
    final status = xhr.status ?? 0;
    final text = xhr.responseText ?? '';
    if (status >= 200 && status < 300) {
      Object? parsed;
      if (text.isNotEmpty) {
        try {
          parsed = jsonDecode(text);
        } catch (_) {
          parsed = null;
        }
      }
      if (!completer.isCompleted) completer.complete(parsed);
      return;
    }
    var message = 'HTTP ' + status.toString();
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['error'] is String) {
        message = decoded['error'] as String;
      }
    } catch (_) {
      // keep the HTTP status message
    }
    if (!completer.isCompleted) completer.completeError(message);
  });
  xhr.onError.listen((_) {
    if (!completer.isCompleted) completer.completeError('网络错误');
  });
  xhr.send(body);
  return completer.future;
}

void refreshFiles(TransferHost host) {
  host.clearFiles();
  final xhr = HttpRequest();
  xhr.open('GET', _filesApi);
  xhr.setRequestHeader('Accept', 'application/json');
  xhr.onLoad.listen((_) {
    final status = xhr.status ?? 0;
    if (status != 200) {
      host.setError('刷新失败（HTTP $status）');
      return;
    }
    try {
      final body = jsonDecode(xhr.responseText ?? '{}') as Map<String, dynamic>;
      final list = (body['files'] as List?) ?? const [];
      for (final item in list) {
        host.addFile(_fileInfoFromJson(item as Map<String, dynamic>));
      }
    } catch (e) {
      host.setError('解析响应失败：$e');
    }
  });
  xhr.onError.listen((_) => host.setError('刷新失败：网络错误'));
  xhr.send();
}

void uploadPickedFiles(dynamic event, TransferHost host) {
  final input = (event as Event).target as InputElement;
  final files = input.files;
  if (files == null || files.isEmpty) return;
  _uploadAll(files, host);
}

void uploadDroppedFiles(dynamic event, TransferHost host) {
  final transfer = (event as MouseEvent).dataTransfer;
  final files = transfer.files;
  if (files == null || files.isEmpty) return;
  _uploadAll(files, host);
}

void _uploadAll(List<File> files, TransferHost host) {
  if (files.isEmpty) return;
  host.setBusy(true);
  var pending = files.length;
  void oneDone() {
    pending -= 1;
    if (pending == 0) {
      host.setBusy(false);
      refreshFiles(host);
    }
  }

  for (final file in files) {
    final id = host.uploadStarted(file.name, file.size);
    if (file.size <= _singleShotLimit) {
      _uploadSingle(file, id, host, oneDone);
    } else {
      _uploadChunked(file, id, host, oneDone);
    }
  }
}

void _uploadSingle(File file, num id, TransferHost host, void Function() oneDone) {
  final started = DateTime.now();
  final form = FormData();
  form.appendBlob('file', file, file.name);
  final xhr = HttpRequest();
  xhr.open('POST', _filesApi);
  xhr.setRequestHeader('X-CSRFToken', _csrfToken());
  xhr.upload.onProgress.listen((ProgressEvent event) {
    final loaded = (event.loaded ?? 0).toInt();
    final total = (event.total ?? 0).toInt();
    if (total > 0) {
      final seconds = DateTime.now().difference(started).inMilliseconds / 1000.0;
      host.uploadProgress(id, 100 * loaded ~/ total, _formatSpeed(loaded, seconds));
    }
  });
  xhr.onLoad.listen((_) {
    final status = xhr.status ?? 0;
    final ok = status >= 200 && status < 300;
    var message = '';
    if (!ok) {
      message = 'HTTP $status';
      try {
        final body = jsonDecode(xhr.responseText ?? '{}') as Map<String, dynamic>;
        message = (body['error'] as String?) ?? message;
      } catch (_) {
        // keep the HTTP status message
      }
    }
    host.uploadFinished(id, ok, message);
    oneDone();
  });
  xhr.onError.listen((_) {
    host.uploadFinished(id, false, '网络错误');
    oneDone();
  });
  xhr.send(form);
}

Future<bool> _putChunk(String uploadId, int index, File file, int chunkSize, int totalBytes,
    void Function(int) onSent) {
  final start = index * chunkSize;
  final end = (start + chunkSize < totalBytes) ? start + chunkSize : totalBytes;
  final blob = file.slice(start, end);
  final xhr = HttpRequest();
  final completer = Completer<bool>();
  xhr.open('PUT', _uploadsApi + uploadId + '/' + index.toString() + '/');
  xhr.setRequestHeader('X-CSRFToken', _csrfToken());
  xhr.setRequestHeader('Content-Type', 'application/octet-stream');
  xhr.upload.onProgress.listen((ProgressEvent event) {
    onSent((event.loaded ?? 0).toInt());
  });
  xhr.onLoad.listen((_) {
    final status = xhr.status ?? 0;
    if (!completer.isCompleted) {
      completer.complete(status >= 200 && status < 300);
    }
  });
  xhr.onError.listen((_) {
    if (!completer.isCompleted) completer.complete(false);
  });
  xhr.send(blob);
  return completer.future;
}

void _uploadChunked(File file, num id, TransferHost host, void Function() oneDone) {
  final started = DateTime.now();
  final totalBytes = file.size;
  var uploadId = '';

  Future<void> run() async {
    final initBody = jsonEncode({
      'name': file.name,
      'size': file.size,
      'content_type': file.type,
    });
    final init = await _request('POST', _uploadsApi, body: initBody, contentType: 'application/json');
    final plan = init as Map<String, dynamic>;
    uploadId = plan['upload_id'] as String;
    final chunkSize = plan['chunk_size'] as int;
    final chunkCount = plan['chunk_count'] as int;

    final sent = List<int>.filled(chunkCount, 0);
    var completedBytes = 0;
    var next = 0;
    var inFlight = 0;
    var failure = '';
    final done = Completer<void>();

    void report() {
      var bytes = completedBytes;
      for (final value in sent) {
        bytes += value;
      }
      final percent = totalBytes > 0 ? (100 * bytes ~/ totalBytes) : 100;
      final seconds = DateTime.now().difference(started).inMilliseconds / 1000.0;
      host.uploadProgress(id, percent, _formatSpeed(bytes, seconds));
    }

    void pump() {
      while (failure.isEmpty && inFlight < _maxParallelChunks && next < chunkCount) {
        final index = next;
        next += 1;
        inFlight += 1;
        _putChunk(uploadId, index, file, chunkSize, totalBytes, (chunkSent) {
          sent[index] = chunkSent;
          report();
        }).then((ok) {
          inFlight -= 1;
          if (!ok) {
            failure = '分片 ' + index.toString() + ' 上传失败';
            if (!done.isCompleted) done.complete();
            return;
          }
          completedBytes += sent[index];
          sent[index] = 0;
          report();
          if (next >= chunkCount && inFlight == 0) {
            if (!done.isCompleted) done.complete();
          } else {
            pump();
          }
        });
      }
    }

    pump();
    await done.future;

    if (failure.isNotEmpty) {
      try {
        await _request('DELETE', _uploadsApi + uploadId + '/');
      } catch (_) {
        // best effort cleanup
      }
      host.uploadFinished(id, false, failure);
      return;
    }

    await _request('POST', _uploadsApi + uploadId + '/complete/');
    host.uploadFinished(id, true, '');
  }

  run().catchError((Object error) async {
    if (uploadId.isNotEmpty) {
      try {
        await _request('DELETE', _uploadsApi + uploadId + '/');
      } catch (_) {
        // best effort cleanup
      }
    }
    host.uploadFinished(id, false, error.toString());
  }).whenComplete(oneDone);
}

void deleteFile(String id, TransferHost host) {
  final xhr = HttpRequest();
  xhr.open('DELETE', '$_filesApi$id/');
  xhr.setRequestHeader('X-CSRFToken', _csrfToken());
  xhr.onLoad.listen((_) {
    final status = xhr.status ?? 0;
    if (status >= 200 && status < 300) {
      refreshFiles(host);
    } else {
      host.setError('删除失败（HTTP $status）');
    }
  });
  xhr.onError.listen((_) => host.setError('删除失败：网络错误'));
  xhr.send();
}
