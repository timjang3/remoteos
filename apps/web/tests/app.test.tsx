import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";

import { App, isInvalidClientError } from "../src/app";

let storedToken: string | null = null;

vi.stubGlobal(
  "window",
  {
    location: {
      search: ""
    },
    localStorage: {
      getItem() {
        return storedToken;
      },
      setItem() {},
      removeItem() {}
    }
  }
);

vi.stubGlobal(
  "localStorage",
  {
    getItem() {
      return storedToken;
    },
    setItem() {},
    removeItem() {}
  }
);

describe("App", () => {
  it("renders the pairing screen by default", () => {
    storedToken = null;
    const html = renderToStaticMarkup(<App />);
    expect(html).toContain("Control your Mac from anywhere.");
  });

  it("keeps the chat composer disabled until the broker connection is ready", () => {
    storedToken = "token_1";
    const html = renderToStaticMarkup(<App />);

    expect(html).toContain("Connecting to your Mac...");
    expect(html).toContain("disabled");
  });

  it("treats unknown-client bootstrap failures as expired sessions", () => {
    storedToken = null;
    expect(isInvalidClientError("Unknown client")).toBe(true);
    expect(isInvalidClientError("Unauthorized client")).toBe(true);
    expect(isInvalidClientError("Failed to bootstrap")).toBe(false);
  });
});
