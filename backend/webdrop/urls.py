from django.contrib import admin
from django.urls import path

from files import views

urlpatterns = [
    path('', views.index, name='index'),
    path('api/health/', views.health, name='health'),
    path('api/files/', views.file_collection, name='file-collection'),
    path('api/files/<uuid:file_id>/', views.file_detail, name='file-detail'),
    path('api/files/<uuid:file_id>/download/', views.file_download, name='file-download'),
    # chunked uploads (big files / flaky links / parallel connections)
    path('api/uploads/', views.upload_init, name='upload-init'),
    path('api/uploads/<uuid:upload_id>/<int:index>/', views.upload_chunk, name='upload-chunk'),
    path('api/uploads/<uuid:upload_id>/', views.upload_abort, name='upload-abort'),
    path('api/uploads/<uuid:upload_id>/complete/', views.upload_complete, name='upload-complete'),
    path('admin/', admin.site.urls),
]
