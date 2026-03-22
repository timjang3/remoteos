import React, { useState } from "react";

import type { ControlPlaneAuthClient } from "../authClient.js";

function GoogleLogo() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24">
      <path d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92a5.06 5.06 0 0 1-2.2 3.32v2.77h3.57c2.08-1.92 3.27-4.74 3.27-8.1z" fill="#4285F4" />
      <path d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" fill="#34A853" />
      <path d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z" fill="#FBBC05" />
      <path d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" fill="#EA4335" />
    </svg>
  );
}

type LoginFormProps = {
  authClient: ControlPlaneAuthClient;
  googleAuthEnabled: boolean;
};

export function LoginForm({ authClient, googleAuthEnabled }: LoginFormProps) {
  const [isPending, setIsPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleGoogleSignIn() {
    if (!googleAuthEnabled) {
      setError("Google sign-in is not configured on this control plane.");
      return;
    }

    setError(null);
    setIsPending(true);

    try {
      const callbackURL =
        typeof window === "undefined" ? "/" : `${window.location.origin}${window.location.pathname}${window.location.search}`;
      await authClient.signIn.social({
        provider: "google",
        callbackURL,
      });
    } catch (submitError) {
      setError(submitError instanceof Error ? submitError.message : "Authentication failed");
    } finally {
      setIsPending(false);
    }
  }

  return (
    <div className="auth-screen">
      <div className="auth-card">
        <div className="pairing-brand auth-brand">
          <div className="pairing-brand-icon">R</div>
          <h1>RemoteOS</h1>
          <p>Sign in to continue</p>
        </div>

        <div className="auth-socials">
          <button
            className="google-signin-btn"
            disabled={isPending || !googleAuthEnabled}
            type="button"
            onClick={() => void handleGoogleSignIn()}
          >
            <GoogleLogo />
            {isPending ? "Signing in..." : "Continue with Google"}
          </button>
        </div>

        {!googleAuthEnabled ? (
          <p className="pairing-error" style={{ marginTop: 16 }}>
            Google sign-in is not configured. Set <code>GOOGLE_CLIENT_ID</code> and{" "}
            <code>GOOGLE_CLIENT_SECRET</code> on the control plane.
          </p>
        ) : null}

        {error ? <p className="pairing-error" style={{ marginTop: 12 }}>{error}</p> : null}
      </div>
    </div>
  );
}
