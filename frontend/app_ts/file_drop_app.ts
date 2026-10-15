import {Component} from '@angular/core';
import {NgFor, NgIf} from '@angular/common';
import {FileInfo, TransferHost, deleteFile, preventDefault, refreshFiles, uploadDroppedFiles, uploadPickedFiles} from './file_transfer';

// Portable-source notes (learned from dart2js): constructor parameter properties
// ("public id: number") become Dart initializing formals, and Dart has no truthiness -
// *ngIf needs a bool expression, so write "error.length > 0" instead of "error".
class Upload {
  percent: number = 0;
  speed: string = '';
  status: string = '等待上传';

  constructor(public id: number, public name: string, public size: number) {}
}

@Component({
  selector: 'file-drop-app',
  template: '<h1>web-drop</h1>' +
      '<p class="hint">把文件拖进虚线框，或点击选择文件。上传后，任何打开这个页面的人都能直接下载。</p>' +
      '<div class="drop" (dragover)="onDragOver($event)" (drop)="onDrop($event)">' +
      '<p>拖拽文件到这里</p>' +
      '<input type="file" multiple (change)="onPicked($event)">' +
      '</div>' +
      '<div class="error" *ngIf="error.length > 0">{{error}}</div>' +
      '<div class="uploads" *ngIf="uploads.length > 0">' +
      '<h2>上传进度</h2>' +
      '<div class="upload" *ngFor="let u of uploads">' +
      '<span class="name">{{u.name}}</span>' +
      '<span class="pct">{{u.percent}}%</span>' +
      '<span class="speed">{{u.speed}}</span>' +
      '<span class="status">{{u.status}}</span>' +
      '</div>' +
      '</div>' +
      '<div class="files">' +
      '<h2>服务器上的文件（{{files.length}}）</h2>' +
      '<p *ngIf="files.length == 0" class="hint">还没有文件。</p>' +
      '<ul>' +
      '<li *ngFor="let f of files">' +
      '<a [href]="f.downloadUrl" download>{{f.name}}</a>' +
      '<span class="meta">{{f.sizeLabel}} · {{f.uploadedAt}}</span>' +
      '<button (click)="onDelete(f)">删除</button>' +
      '</li>' +
      '</ul>' +
      '</div>' +
      '<button class="refresh" [disabled]="busy" (click)="onRefresh()">刷新列表</button>',
  directives: [NgFor, NgIf],
})
export class FileDropApp implements TransferHost {
  files: FileInfo[] = [];
  uploads: Upload[] = [];
  error: string = '';
  busy: boolean = false;
  private nextUploadId: number = 1;

  constructor() {
    refreshFiles(this);
  }

  uploadStarted(name: string, size: number): number {
    const id = this.nextUploadId++;
    this.uploads.push(new Upload(id, name, size));
    return id;
  }

  uploadProgress(id: number, percent: number, speed: string): void {
    for (let i = 0; i < this.uploads.length; i++) {
      if (this.uploads[i].id == id) {
        this.uploads[i].percent = percent;
        this.uploads[i].speed = speed;
        this.uploads[i].status = '上传中';
      }
    }
  }

  uploadFinished(id: number, ok: boolean, message: string): void {
    for (let i = 0; i < this.uploads.length; i++) {
      if (this.uploads[i].id == id) {
        this.uploads[i].status = ok ? '完成' : '失败：' + message;
        if (ok) {
          this.uploads[i].percent = 100;
          this.uploads[i].speed = '';
        }
      }
    }
  }

  clearFiles(): void {
    this.files = [];
  }

  addFile(info: FileInfo): void {
    this.files.push(info);
  }

  setError(message: string): void {
    this.error = message;
  }

  setBusy(busy: boolean): void {
    this.busy = busy;
  }

  onDragOver(event: any): void {
    preventDefault(event);
  }

  onDrop(event: any): void {
    this.error = '';
    uploadDroppedFiles(event, this);
  }

  onPicked(event: any): void {
    this.error = '';
    uploadPickedFiles(event, this);
  }

  onDelete(file: FileInfo): void {
    this.error = '';
    deleteFile(file.id, this);
  }

  onRefresh(): void {
    this.error = '';
    refreshFiles(this);
  }
}
