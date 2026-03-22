import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { setResolvedControlPlaneAuth } from "../src/api";
import {
  getStoredToken,
  logoutWebSession,
  setStoredToken
} from "../src/session";

const originalWindow = globalThis.window;

function installWindow(href: string) {
  const storage = new Map<string, string>();

  vi.stubGlobal("window", {
    location: new URL(href),
    localStorage: {
      getItem(key: string) {
        return storage.get(key) ?? null;
      },
      setItem(key: string, value: string) {
        storage.set(key, value);
      },
      removeItem(key: string) {
        storage.delete(key);
      }
    }
  });
}

describe("web logout", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  afterEach(() => {
    if (originalWindow === undefined) {
      // @ts-expect-error test cleanup
      delete globalThis.window;
    } else {
      vi.stubGlobal("window", originalWindow);
    }
  });

  it("clears the paired browser token and signs out when hosted auth is required", async () => {
    installWindow("http://localhost:5173");
    setResolvedControlPlaneAuth("http://localhost:8787", "required");
    setStoredToken("token_1");
    const signOut = vi.fn().mockResolvedValue({});

    await logoutWebSession({ signOut } as any);

    expect(getStoredToken()).toBeNull();
    expect(signOut).toHaveBeenCalledTimes(1);
  });

  it("clears the paired browser token without requiring auth sign-out in authless mode", async () => {
    installWindow("http://localhost:5173");
    setResolvedControlPlaneAuth("http://localhost:8787", "none");
    setStoredToken("token_1");
    const signOut = vi.fn().mockResolvedValue({});

    await logoutWebSession({ signOut } as any);

    expect(getStoredToken()).toBeNull();
    expect(signOut).not.toHaveBeenCalled();
  });
});
