library file_drop_app;

import "package:ngdart/angular.dart" show Component;
import "package:ngdart/angular.dart" show NgFor, NgIf;
import "file_transfer.dart"
    show
        FileInfo,
        TransferHost,
        deleteFile,
        preventDefault,
        refreshFiles,
        uploadDroppedFiles,
        uploadPickedFiles;
// Portable-source notes (learned by compiling with dart2js):

//   * constructor parameter properties ("public id: number") become Dart

//     initializing formals; assigning fields inside the constructor body does

//     not satisfy null-safe Dart's definite assignment.

//   * Dart has no truthiness: *ngIf needs a bool expression, so write

//     "error.length > 0" instead of "error".
class Upload {
  num id;
  String name;
  num size;
  num percent = 0;
  String speed = "";
  String status = "等待上传";
  Upload(this.id, this.name, this.size) {}
}

@Component(
    selector: "file-drop-app",
    template: "<h1>web-drop</h1>" +
        "<p class=\"hint\">把文件拖进虚线框，或点击选择文件。上传后，任何打开这个页面的人都能直接下载。</p>" +
        "<div class=\"drop\" (dragover)=\"onDragOver(\$event)\" (drop)=\"onDrop(\$event)\">" +
        "<p>拖拽文件到这里</p>" +
        "<input type=\"file\" multiple (change)=\"onPicked(\$event)\">" +
        "</div>" +
        "<div class=\"error\" *ngIf=\"error.length > 0\">{{error}}</div>" +
        "<div class=\"uploads\" *ngIf=\"uploads.length > 0\">" +
        "<h2>上传进度</h2>" +
        "<div class=\"upload\" *ngFor=\"let u of uploads\">" +
        "<span class=\"name\">{{u.name}}</span>" +
        "<span class=\"pct\">{{u.percent}}%</span>" +
        "<span class=\"speed\">{{u.speed}}</span>" +
        "<span class=\"status\">{{u.status}}</span>" +
        "</div>" +
        "</div>" +
        "<div class=\"files\">" +
        "<h2>服务器上的文件（{{files.length}}）</h2>" +
        "<p *ngIf=\"files.length == 0\" class=\"hint\">还没有文件。</p>" +
        "<ul>" +
        "<li *ngFor=\"let f of files\">" +
        "<a [href]=\"f.downloadUrl\" download>{{f.name}}</a>" +
        "<span class=\"meta\">{{f.sizeLabel}} · {{f.uploadedAt}}</span>" +
        "<button (click)=\"onDelete(f)\">删除</button>" +
        "</li>" +
        "</ul>" +
        "</div>" +
        "<button class=\"refresh\" [disabled]=\"busy\" (click)=\"onRefresh()\">刷新列表</button>",
    directives: const [NgFor, NgIf])
class FileDropApp implements TransferHost {
  List<FileInfo> files = [];
  List<Upload> uploads = [];
  String error = "";
  bool busy = false;
  num nextUploadId = 1;
  FileDropApp() {
    refreshFiles(this);
  }
  num uploadStarted(String name, num size) {
    final id = this.nextUploadId++;
    this.uploads.add(new Upload(id, name, size));
    return id;
  }

  void uploadProgress(num id, num percent, String speed) {
    for (var i = 0; i < this.uploads.length; i++) {
      if (this.uploads[i].id == id) {
        this.uploads[i].percent = percent;
        this.uploads[i].speed = speed;
        this.uploads[i].status = "上传中";
      }
    }
  }

  void uploadFinished(num id, bool ok, String message) {
    for (var i = 0; i < this.uploads.length; i++) {
      if (this.uploads[i].id == id) {
        this.uploads[i].status = ok ? "完成" : "失败：" + message;
        if (ok) {
          this.uploads[i].percent = 100;
          this.uploads[i].speed = "";
        }
      }
    }
  }

  void clearFiles() {
    this.files = [];
  }

  void addFile(FileInfo info) {
    this.files.add(info);
  }

  void setError(String message) {
    this.error = message;
  }

  void setBusy(bool busy) {
    this.busy = busy;
  }

  void onDragOver(dynamic event) {
    preventDefault(event);
  }

  void onDrop(dynamic event) {
    this.error = "";
    uploadDroppedFiles(event, this);
  }

  void onPicked(dynamic event) {
    this.error = "";
    uploadPickedFiles(event, this);
  }

  void onDelete(FileInfo file) {
    this.error = "";
    deleteFile(file.id, this);
  }

  void onRefresh() {
    this.error = "";
    refreshFiles(this);
  }
}
