import { BACKEND_URL, SESSION_HEADER, problemMessage } from '@/lib/backend';

/** File-attachment upload + status polling against the backend's `POST /files` ingestion pipeline. */

/** Upload size cap (keep in sync with the backend `MAX_UPLOAD_MB`). */
export const MAX_UPLOAD_MB = 10;
export const MAX_BYTES = MAX_UPLOAD_MB * 1024 * 1024;

/** Accepted extensions, mirroring the backend `SupportedFileTypes`; used for the file dialog's `accept` and client-side validation. */
export const ACCEPT_EXTENSIONS = [
  'pdf', 'jpg', 'jpeg', 'png', 'bmp', 'tiff', 'tif', 'heif', 'heic', 'docx', 'xlsx', 'pptx', 'html', 'htm',
  'txt', 'csv', 'md', 'json', 'tsv',
] as const;

export const ACCEPT = ACCEPT_EXTENSIONS.map((ext) => `.${ext}`).join(',');

const ALLOWED = new Set<string>(ACCEPT_EXTENSIONS);

export type FileStatus = 'uploading' | 'indexed' | 'error';

/** One attachment tracked in the composer. `id` is a client-side key; `fileId` is the backend's. */
export type FileAttachment = {
  id: string;
  name: string;
  size: number;
  status: FileStatus;
  fileId?: string;
  chunkCount?: number;
  error?: string;
  file: File;
};

function extensionOf(name: string): string {
  const dot = name.lastIndexOf('.');
  return dot >= 0 ? name.slice(dot + 1).toLowerCase() : '';
}

/** Client-side guard mirroring the backend's checks; returns an error message or null if the file is OK. */
export function validateFile(file: File): string | null {
  if (!ALLOWED.has(extensionOf(file.name))) {
    return 'Unsupported file type.';
  }
  if (file.size > MAX_BYTES) {
    return `File exceeds the ${MAX_UPLOAD_MB} MB limit.`;
  }
  return null;
}

/** Async ingestion status: `POST /files` returns `processing`; the SPA polls `GET /files/{fileId}` until `indexed`/`failed`. */
export type IngestionStatus = 'processing' | 'indexed' | 'failed';

export type FileStatusResult = {
  fileId: string;
  fileName: string;
  status: IngestionStatus;
  chunkCount?: number;
  error?: string;
};

const FILES_URL = `${BACKEND_URL.replace(/\/$/, '')}/files`;

const POLL_INTERVAL_MS = 2000;
const POLL_TIMEOUT_MS = 5 * 60 * 1000;

/** Thrown by `pollFileStatus` when the caller cancels (attachment removed / view unmounted). */
export class PollCancelledError extends Error {}

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Uploads one file for ingestion; resolves with the initial (`processing`) status, or throws with the backend's own wording (413/409/429). */
export async function uploadFile(sessionId: string, file: File): Promise<FileStatusResult> {
  const body = new FormData();
  body.append('file', file);
  body.append('sessionId', sessionId);

  let response: Response;
  try {
    // The backend rate-limits uploads per conversation and can't read the multipart body to partition on it.
    response = await fetch(FILES_URL, { method: 'POST', body, headers: { [SESSION_HEADER]: sessionId } });
  } catch {
    throw new Error('Network error — could not reach the backend.');
  }

  if (!response.ok) {
    throw new Error(await problemMessage(response, `Upload failed (${response.status}).`));
  }

  return (await response.json()) as FileStatusResult;
}

/** Lists the session's attachments for the files panel. Degrades to `[]` if the backend is unreachable. */
export async function listFiles(sessionId: string): Promise<FileStatusResult[]> {
  try {
    const url = `${FILES_URL}?sessionId=${encodeURIComponent(sessionId)}`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`files ${res.status}`);
    const data = (await res.json()) as { files?: FileStatusResult[] };
    return Array.isArray(data.files) ? data.files : [];
  } catch {
    return [];
  }
}

/** Deletes a single attachment (purges its blobs, chunks, and status row). Resolves true on success. */
export async function deleteFile(sessionId: string, fileId: string): Promise<boolean> {
  const url = `${FILES_URL}/${encodeURIComponent(fileId)}?sessionId=${encodeURIComponent(sessionId)}`;
  try {
    const res = await fetch(url, { method: 'DELETE' });
    if (!res.ok) throw new Error(await problemMessage(res, `Delete failed (${res.status}).`));
    return true;
  } catch {
    return false;
  }
}

/** Reads a file's current ingestion status. */
export async function getFileStatus(sessionId: string, fileId: string): Promise<FileStatusResult> {
  const url = `${FILES_URL}/${encodeURIComponent(fileId)}?sessionId=${encodeURIComponent(sessionId)}`;
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(await problemMessage(response, `Status check failed (${response.status}).`));
  }
  return (await response.json()) as FileStatusResult;
}

/** Polls the file's status until terminal (`indexed`/`failed`), the caller cancels, or the timeout elapses (treated as failure). Transient errors are tolerated. */
export async function pollFileStatus(
  sessionId: string,
  fileId: string,
  isCancelled: () => boolean,
): Promise<FileStatusResult> {
  const start = Date.now();
  while (!isCancelled()) {
    await delay(POLL_INTERVAL_MS);
    if (isCancelled()) break;

    try {
      const status = await getFileStatus(sessionId, fileId);
      if (status.status !== 'processing') return status;
    } catch {
      // transient — keep polling until the timeout below
    }

    if (Date.now() - start > POLL_TIMEOUT_MS) {
      return { fileId, fileName: '', status: 'failed', error: 'Indexing timed out.' };
    }
  }
  throw new PollCancelledError();
}
