import type {
  SpeechCapabilities,
  SpeechProvider
} from "@remoteos/contracts";
import { z } from "zod";

import type { ControlPlaneConfig } from "./config.js";

const OPENAI_TRANSCRIPTION_URL = "https://api.openai.com/v1/audio/transcriptions";
const OPENAI_TRANSCRIPTION_PROMPT =
  "Transcribe the user's speech as clean, punctuated text. Preserve product names exactly when heard, including RemoteOS, Codex, GPT-5.4, and Mac.";
const openAITranscriptionResponseSchema = z.object({
  text: z.string()
});

export const supportedSpeechMimeTypes = new Set([
  "audio/mp4",
  "audio/mpeg",
  "audio/mp3",
  "audio/m4a",
  "audio/ogg",
  "audio/wav",
  "audio/webm",
  "audio/x-m4a",
  "audio/x-wav"
]);

export type SpeechTranscriptionResult = {
  text: string;
  provider: SpeechProvider;
  model: string;
};

export type SpeechTranscriptionInput = {
  audio: Buffer;
  mimeType: string;
  filename: string;
  language?: string;
  signal?: AbortSignal;
};

export interface SpeechTranscriptionProvider {
  readonly provider: SpeechProvider;
  readonly model: string;
  transcribe(input: SpeechTranscriptionInput): Promise<SpeechTranscriptionResult>;
}

export function buildSpeechCapabilities(config: ControlPlaneConfig): SpeechCapabilities {
  return {
    transcriptionAvailable: config.speech.transcriptionAvailable,
    provider: config.speech.transcriptionAvailable ? config.speech.provider : null,
    maxDurationMs: config.speech.maxDurationMs,
    maxUploadBytes: config.speech.maxUploadBytes
  };
}

export function normalizeSpeechMimeType(value: string) {
  return value.split(";", 1)[0]?.trim().toLowerCase() ?? "";
}

export function extensionForSpeechMimeType(mimeType: string) {
  switch (normalizeSpeechMimeType(mimeType)) {
    case "audio/mp4":
    case "audio/m4a":
    case "audio/x-m4a":
      return "m4a";
    case "audio/mpeg":
    case "audio/mp3":
      return "mp3";
    case "audio/ogg":
      return "ogg";
    case "audio/wav":
    case "audio/x-wav":
      return "wav";
    case "audio/webm":
    default:
      return "webm";
  }
}

class OpenAISpeechTranscriptionProvider implements SpeechTranscriptionProvider {
  readonly provider = "openai" as const;

  constructor(
    readonly model: string,
    private readonly apiKey: string
  ) {}

  async transcribe(input: SpeechTranscriptionInput) {
    const form = new FormData();
    form.set("model", this.model);
    form.set("file", new Blob([new Uint8Array(input.audio)], { type: input.mimeType }), input.filename);
    form.set("prompt", OPENAI_TRANSCRIPTION_PROMPT);
    if (input.language) {
      form.set("language", input.language);
    }

    const response = await fetch(OPENAI_TRANSCRIPTION_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.apiKey}`
      },
      body: form,
      ...(input.signal ? { signal: input.signal } : {})
    });

    const bodyText = await response.text();
    let payload: unknown = null;
    if (bodyText) {
      try {
        payload = JSON.parse(bodyText);
      } catch {
        payload = {
          text: bodyText
        };
      }
    }
    if (!response.ok) {
      const message =
        typeof payload === "object"
          && payload
          && "error" in payload
          && typeof payload.error === "object"
          && payload.error
          && "message" in payload.error
          && typeof payload.error.message === "string"
          ? payload.error.message
          : `OpenAI transcription failed with status ${response.status}`;
      throw new Error(message);
    }

    const parsed = openAITranscriptionResponseSchema.parse(payload);
    return {
      text: parsed.text.trim(),
      provider: this.provider,
      model: this.model
    };
  }
}

export function createSpeechTranscriptionProvider(config: ControlPlaneConfig): SpeechTranscriptionProvider | null {
  if (!config.speech.transcriptionAvailable || !config.speech.provider) {
    return null;
  }

  if (config.speech.provider === "openai") {
    if (!config.speech.openAIAPIKey) {
      return null;
    }

    return new OpenAISpeechTranscriptionProvider(config.speech.model, config.speech.openAIAPIKey);
  }

  return null;
}
