import uuid
from pathlib import Path

from django.conf import settings
from django.db import models


class StoredFile(models.Model):
    """Metadata for a file stored under MEDIA_ROOT/uploads/."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    original_name = models.CharField(max_length=255)
    size = models.BigIntegerField()
    content_type = models.CharField(max_length=255, blank=True)
    stored_name = models.CharField(max_length=255, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return self.original_name

    @property
    def path(self) -> Path:
        return Path(settings.MEDIA_ROOT) / 'uploads' / self.stored_name

    def to_json(self) -> dict:
        return {
            'id': str(self.id),
            'name': self.original_name,
            'size': self.size,
            'content_type': self.content_type,
            'created_at': self.created_at.isoformat(),
            'download_url': f'/api/files/{self.id}/download/',
        }


class UploadSession(models.Model):
    """A chunked upload in progress (see files/views.py).

    Chunks live on disk in MEDIA_ROOT/tmp/<id>/<index>.part; when the client
    posts /complete/ they are concatenated into MEDIA_ROOT/uploads/ and this row
    is turned into a StoredFile. Aborted or abandoned sessions are swept away
    when the next session is created.
    """

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    original_name = models.CharField(max_length=255)
    content_type = models.CharField(max_length=255, blank=True)
    total_size = models.BigIntegerField()
    chunk_size = models.IntegerField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    @property
    def chunk_count(self) -> int:
        if self.total_size <= 0:
            return 1
        return (self.total_size + self.chunk_size - 1) // self.chunk_size

    @property
    def dir(self) -> Path:
        return Path(settings.MEDIA_ROOT) / 'tmp' / str(self.id)

    def expected_chunk_size(self, index: int) -> int:
        """Size of chunk <index> (the last one may be short)."""
        start = index * self.chunk_size
        return min(self.chunk_size, self.total_size - start)
