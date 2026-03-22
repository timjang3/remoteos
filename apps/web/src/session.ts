import { getResolvedControlPlaneAuthMode } from "./api.js";
import type { ControlPlaneAuthClient } from "./authClient.js";

const clientTokenStorageKey = "remoteos.clientToken";

export function getStoredToken() {
  if (typeof window === "undefined") return null;
  return window.localStorage.getItem(clientTokenStorageKey);
}

export function setStoredToken(token: string) {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(clientTokenStorageKey, token);
}

export function clearStoredToken() {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(clientTokenStorageKey);
}

export async function logoutWebSession(
  authClient?: Pick<ControlPlaneAuthClient, "signOut"> | null
) {
  clearStoredToken();

  if (getResolvedControlPlaneAuthMode() !== "required") {
    return;
  }

  await authClient?.signOut();
}
