/** User-tunable chat settings, persisted in localStorage; shaped as an object so future toggles slot in without touching call sites. */

/** Reasoning effort levels the backend maps to the Responses API `reasoning.effort`. */
export const REASONING_EFFORTS = ['minimal', 'low', 'medium', 'high'] as const;
export type ReasoningEffort = (typeof REASONING_EFFORTS)[number];

export type ChatSettings = {
  reasoningEffort: ReasoningEffort;
  // Selected chat model deployment (one of AppConfig.models); undefined ⇒ the backend default. Global, not per-session.
  model?: string;
  // When true, ground answers strictly in attached documents (RAG only); false ⇒ RAG + general model knowledge.
  ragOnly: boolean;
};

const STORAGE_KEY = 'agent.settings';
const DEFAULTS: ChatSettings = { reasoningEffort: 'medium', ragOnly: false };

/** Read the persisted settings, falling back to defaults for anything missing or malformed. */
export function getSettings(): ChatSettings {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return DEFAULTS;
    const parsed = JSON.parse(raw) as Partial<ChatSettings>;
    return {
      reasoningEffort: REASONING_EFFORTS.includes(parsed.reasoningEffort as ReasoningEffort)
        ? (parsed.reasoningEffort as ReasoningEffort)
        : DEFAULTS.reasoningEffort,
      model: typeof parsed.model === 'string' && parsed.model ? parsed.model : undefined,
      ragOnly: typeof parsed.ragOnly === 'boolean' ? parsed.ragOnly : DEFAULTS.ragOnly,
    };
  } catch {
    return DEFAULTS;
  }
}

/** Persist a partial update and return the merged settings. */
export function saveSettings(update: Partial<ChatSettings>): ChatSettings {
  const next = { ...getSettings(), ...update };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  return next;
}
