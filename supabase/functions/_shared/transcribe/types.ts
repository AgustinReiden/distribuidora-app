// Interface común para los transcriptores de audio. Permite swappear el
// provider (Gemini / OpenAI / Groq) sin tocar el handler — la elección
// vive en una env var (BOT_TRANSCRIPTION_MODEL).

export interface Transcriber {
  /** Nombre del provider. Útil para audit log + diagnóstico. */
  readonly name: string;
  /**
   * Devuelve el texto transcripto del audio.
   * @param audio Bytes crudos del archivo (típicamente Ogg Opus de Telegram).
   * @param mimeType MIME type. Default "audio/ogg" si Telegram no lo manda.
   *
   * Lanza si la red falla o el provider rechaza. El caller decide si
   * reintentar o degradar a "no pude transcribir".
   */
  transcribe(audio: Uint8Array, mimeType: string): Promise<string>;
}
