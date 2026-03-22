import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { EmptyState, PhoneShell } from "../src/index.js";

describe("ui-web", () => {
  it("renders the phone shell", () => {
    const html = renderToStaticMarkup(
      <PhoneShell title="Deck" subtitle="Connected">
        <EmptyState title="Nothing yet" detail="Waiting for a host" />
      </PhoneShell>
    );

    expect(html).toContain("RemoteOS");
    expect(html).toContain("Waiting for a host");
  });
});
