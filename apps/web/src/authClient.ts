import { createAuthClient } from "better-auth/react";

export function createControlPlaneAuthClient(baseUrl: string): ReturnType<typeof createAuthClient> {
  return createAuthClient({
    baseURL: `${baseUrl}/api/auth`,
    fetchOptions: {
      credentials: "include"
    }
  });
}

export type ControlPlaneAuthClient = ReturnType<typeof createControlPlaneAuthClient>;
