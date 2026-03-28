import React, { useEffect, useMemo, useState } from "react";

import type {
  ControlPlaneAuthMode,
  DeviceEnrollmentPayload
} from "../api.js";
import {
  approveEnrollment,
  getEnrollment,
  getHealth,
  resolveControlPlaneBaseUrl,
  setResolvedControlPlaneAuth,
  storeControlPlaneBaseUrl
} from "../api.js";
import {
  createControlPlaneAuthClient,
  type ControlPlaneAuthClient
} from "../authClient.js";
import { logoutWebSession } from "../session.js";
import { LoginForm } from "./LoginForm.js";
import { RemoteOSBrandHeader } from "./RemoteOSBranding.js";

type AuthGateProps = {
  children: React.ReactNode;
};

function HostedEnrollmentView({
  authClient,
  baseUrl,
  enrollmentToken
}: {
  authClient: ControlPlaneAuthClient;
  baseUrl: string;
  enrollmentToken: string;
}) {
  const session = authClient.useSession();
  const [enrollment, setEnrollment] = useState<DeviceEnrollmentPayload | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isApproving, setIsApproving] = useState(false);

  useEffect(() => {
    let cancelled = false;

    async function loadEnrollment() {
      try {
        const result = await getEnrollment(baseUrl, enrollmentToken);
        if (cancelled) {
          return;
        }
        setEnrollment(result.data);
        setError(null);
      } catch (loadError) {
        if (!cancelled) {
          setError(loadError instanceof Error ? loadError.message : "Failed to load enrollment");
        }
      } finally {
        if (!cancelled) {
          setIsLoading(false);
        }
      }
    }

    void loadEnrollment();
    return () => {
      cancelled = true;
    };
  }, [baseUrl, enrollmentToken]);

  async function handleApprove() {
    setIsApproving(true);
    setError(null);
    try {
      const result = await approveEnrollment(baseUrl, enrollmentToken);
      setEnrollment(result.data);
      storeControlPlaneBaseUrl(result.baseUrl);
    } catch (approveError) {
      setError(approveError instanceof Error ? approveError.message : "Failed to approve Mac");
    } finally {
      setIsApproving(false);
    }
  }

  async function handleSignOut() {
    setError(null);

    try {
      await logoutWebSession(authClient);
      if (typeof window !== "undefined") {
        window.location.assign(window.location.pathname);
      }
    } catch (signOutError) {
      setError(signOutError instanceof Error ? signOutError.message : "Failed to sign out");
    }
  }

  return (
    <div className="auth-screen">
      <div className="auth-card auth-card-wide">
        <RemoteOSBrandHeader
          className="auth-brand"
          title="Authorize This Mac"
          subtitle={session.data?.user.email ?? "Signed in"}
        />

        {isLoading ? (
          <div style={{ display: "flex", justifyContent: "center", padding: "24px 0" }}>
            <div className="auth-loading-spinner" />
          </div>
        ) : enrollment ? (
          <div className="auth-token-card">
            {enrollment.status === "approved" ? (
              <div className="enrollment-status">
                <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="var(--success)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14" />
                  <polyline points="22 4 12 14.01 9 11.01" />
                </svg>
                <p className="enrollment-status-title">{enrollment.deviceName} is authorized</p>
                <p className="enrollment-status-subtitle">Return to the Mac app to finish connecting.</p>
              </div>
            ) : enrollment.status === "expired" ? (
              <div className="enrollment-status">
                <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="var(--warning)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <circle cx="12" cy="12" r="10" />
                  <line x1="12" y1="8" x2="12" y2="12" />
                  <line x1="12" y1="16" x2="12.01" y2="16" />
                </svg>
                <p className="enrollment-status-title">Request expired</p>
                <p className="enrollment-status-subtitle">Start enrollment again from the Mac app.</p>
              </div>
            ) : (
              <>
                <p>
                  Approve <strong>{enrollment.deviceName}</strong> to connect to your hosted control plane.
                </p>
                <div className="enrollment-details">
                  <div className="enrollment-detail-row">
                    <span className="enrollment-detail-label">Device</span>
                    <span className="enrollment-detail-value">{enrollment.deviceName}</span>
                  </div>
                  <div className="enrollment-detail-row">
                    <span className="enrollment-detail-label">Mode</span>
                    <span className="enrollment-detail-value">{enrollment.deviceMode}</span>
                  </div>
                  <div className="enrollment-detail-row">
                    <span className="enrollment-detail-label">Expires</span>
                    <span className="enrollment-detail-value">{new Date(enrollment.expiresAt).toLocaleString()}</span>
                  </div>
                </div>
                <div className="auth-token-actions">
                  <button
                    className="pairing-button"
                    disabled={isApproving}
                    type="button"
                    onClick={() => void handleApprove()}
                  >
                    {isApproving ? "Approving..." : "Approve this Mac"}
                  </button>
                  <button
                    className="auth-secondary-button"
                    type="button"
                    onClick={() => void handleSignOut()}
                  >
                    Sign out
                  </button>
                </div>
              </>
            )}
          </div>
        ) : null}

        {error ? <p className="pairing-error">{error}</p> : null}
      </div>
    </div>
  );
}

function AuthRequiredGate({
  authClient,
  baseUrl,
  googleAuthEnabled,
  children
}: {
  authClient: ControlPlaneAuthClient;
  baseUrl: string;
  googleAuthEnabled: boolean;
  children: React.ReactNode;
}) {
  const session = authClient.useSession();
  const enrollmentToken =
    typeof window !== "undefined"
      ? new URLSearchParams(window.location.search).get("enroll")
      : null;

  if (session.isPending) {
    return (
      <div className="auth-screen">
        <div className="auth-card">
          <RemoteOSBrandHeader className="auth-brand" title="RemoteOS" />
          <div style={{ display: "flex", justifyContent: "center", padding: "8px 0" }}>
            <div className="auth-loading-spinner" />
          </div>
        </div>
      </div>
    );
  }

  if (!session.data) {
    return <LoginForm authClient={authClient} googleAuthEnabled={googleAuthEnabled} />;
  }

  if (enrollmentToken) {
    return (
      <HostedEnrollmentView
        authClient={authClient}
        baseUrl={baseUrl}
        enrollmentToken={enrollmentToken}
      />
    );
  }

  return <>{children}</>;
}

export function AuthGate({ children }: AuthGateProps) {
  const [baseUrl, setBaseUrl] = useState(() => resolveControlPlaneBaseUrl());
  const [authMode, setAuthMode] = useState<ControlPlaneAuthMode | null>(null);
  const [googleAuthEnabled, setGoogleAuthEnabled] = useState(false);
  const [healthError, setHealthError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function loadHealth() {
      try {
        const result = await getHealth(baseUrl);
        if (cancelled) {
          return;
        }

        storeControlPlaneBaseUrl(result.baseUrl);
        setResolvedControlPlaneAuth(result.baseUrl, result.data.authMode);
        setBaseUrl(result.baseUrl);
        setAuthMode(result.data.authMode);
        setGoogleAuthEnabled(result.data.googleAuthEnabled);
        setHealthError(null);
      } catch (error) {
        if (!cancelled) {
          setHealthError(error instanceof Error ? error.message : "Failed to reach control plane");
        }
      }
    }

    void loadHealth();
    return () => {
      cancelled = true;
    };
  }, [baseUrl]);

  if (healthError) {
    return (
      <div className="auth-screen">
        <div className="auth-card">
          <RemoteOSBrandHeader className="auth-brand" title="RemoteOS" subtitle={healthError} />
        </div>
      </div>
    );
  }

  if (!authMode) {
    return (
      <div className="auth-screen">
        <div className="auth-card">
          <RemoteOSBrandHeader className="auth-brand" title="RemoteOS" />
          <div style={{ display: "flex", justifyContent: "center", padding: "8px 0" }}>
            <div className="auth-loading-spinner" />
          </div>
        </div>
      </div>
    );
  }

  if (authMode === "none") {
    return <>{children}</>;
  }

  const authClient = createControlPlaneAuthClient(baseUrl);

  return (
    <AuthRequiredGate authClient={authClient} baseUrl={baseUrl} googleAuthEnabled={googleAuthEnabled}>
      {children}
    </AuthRequiredGate>
  );
}
