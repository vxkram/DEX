// Hands a file from one extension page to another (popup → editor tab):
// a blob URL dies with the page that made it, IndexedDB doesn't.

const open = () => new Promise<IDBDatabase>((resolve, reject) => {
  const request = indexedDB.open('dex', 1);
  request.onupgradeneeded = () => request.result.createObjectStore('files');
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(request.error);
});

async function run<T>(mode: IDBTransactionMode, body: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await open();
  return new Promise<T>((resolve, reject) => {
    const request = body(db.transaction('files', mode).objectStore('files'));
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }).finally(() => db.close());
}

export interface StoredFile { blob: Blob; name: string }

export async function putFile(file: StoredFile): Promise<string> {
  const id = crypto.randomUUID();
  await run('readwrite', (store) => store.put(file, id));
  return id;
}

/** Reads a file once; it's removed as it's taken. */
export async function takeFile(id: string): Promise<StoredFile | undefined> {
  const file = await run<StoredFile | undefined>('readonly', (store) => store.get(id));
  await run('readwrite', (store) => store.delete(id));
  return file;
}
