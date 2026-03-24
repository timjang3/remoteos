const preferredDictationMimeTypes = [
  "audio/webm;codecs=opus",
  "audio/webm",
  "audio/mp4"
] as const;

export function pickDictationMimeType(
  mediaRecorderCtor: Pick<typeof MediaRecorder, "isTypeSupported"> | undefined = globalThis.MediaRecorder
) {
  if (!mediaRecorderCtor?.isTypeSupported) {
    return null;
  }

  for (const mimeType of preferredDictationMimeTypes) {
    if (mediaRecorderCtor.isTypeSupported(mimeType)) {
      return mimeType;
    }
  }

  return null;
}

export function extensionForDictationMimeType(mimeType: string) {
  const normalized = mimeType.split(";", 1)[0]?.trim().toLowerCase() ?? "";
  if (normalized === "audio/mp4") {
    return "m4a";
  }

  return "webm";
}

function needsLeadingSpace(text: string, index: number) {
  return index > 0 && !/\s/.test(text[index - 1] ?? "");
}

function needsTrailingSpace(text: string, index: number) {
  return index < text.length && !/\s/.test(text[index] ?? "");
}

export function insertDictationText(
  currentText: string,
  transcript: string,
  selectionStart = currentText.length,
  selectionEnd = selectionStart
) {
  const cleanTranscript = transcript.trim();
  if (!cleanTranscript) {
    return {
      text: currentText,
      selection: selectionEnd
    };
  }

  const prefix = needsLeadingSpace(currentText, selectionStart) ? " " : "";
  const suffix = selectionStart === selectionEnd && needsTrailingSpace(currentText, selectionEnd) ? " " : "";
  const inserted = `${prefix}${cleanTranscript}${suffix}`;
  const nextText = `${currentText.slice(0, selectionStart)}${inserted}${currentText.slice(selectionEnd)}`;
  const nextSelection = selectionStart + inserted.length;

  return {
    text: nextText,
    selection: nextSelection
  };
}
