const STORAGE_KEY = 'agent.sessionId';

/** The conversation id (localStorage), stable across reloads since the backend keys chat history by it. */
export function getSessionId(): string {
  let id = localStorage.getItem(STORAGE_KEY);
  if (!id) {
    id = crypto.randomUUID();
    localStorage.setItem(STORAGE_KEY, id);
  }
  return id;
}

/** Start a fresh conversation: mint a new id and drop the old one. */
export function resetSessionId(): string {
  const id = crypto.randomUUID();
  localStorage.setItem(STORAGE_KEY, id);
  return id;
}

/** Switch the active conversation to an existing id (selecting a past session from the sidebar). */
export function setSessionId(id: string): string {
  localStorage.setItem(STORAGE_KEY, id);
  return id;
}
