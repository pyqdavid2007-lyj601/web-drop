from django.contrib import admin

from .models import StoredFile


@admin.register(StoredFile)
class StoredFileAdmin(admin.ModelAdmin):
    list_display = ('original_name', 'size', 'content_type', 'created_at')
    search_fields = ('original_name',)
