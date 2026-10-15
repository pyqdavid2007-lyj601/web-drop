// TypeScript-side contract for the file_transfer facade: types only - the implementation is
// hand-written Dart (app_ts/file_transfer.dart), so there is nothing to keep in sync.
export interface FileInfo {
  id: string;
  name: string;
  sizeLabel: string;
  uploadedAt: string;
  downloadUrl: string;
}

export interface TransferHost {
  uploadStarted(name: string, size: number): number;
  uploadProgress(id: number, percent: number, speed: string): void;
  uploadFinished(id: number, ok: boolean, message: string): void;
  clearFiles(): void;
  addFile(info: FileInfo): void;
  setError(message: string): void;
  setBusy(busy: boolean): void;
}

export declare function preventDefault(event: any): void;
export declare function refreshFiles(host: TransferHost): void;
export declare function uploadPickedFiles(event: any, host: TransferHost): void;
export declare function uploadDroppedFiles(event: any, host: TransferHost): void;
export declare function deleteFile(id: string, host: TransferHost): void;
