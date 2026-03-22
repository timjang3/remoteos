import type { HTMLAttributes, PropsWithChildren } from "react";

import React from "react";

export function PhoneShell({
  title,
  subtitle,
  children
}: PropsWithChildren<{ title: string; subtitle?: string }>) {
  return (
    <div className="remoteos-shell">
      <header className="remoteos-shell__header">
        <p className="remoteos-shell__eyebrow">RemoteOS</p>
        <h1>{title}</h1>
        {subtitle ? <p className="remoteos-shell__subtitle">{subtitle}</p> : null}
      </header>
      <main className="remoteos-shell__main">{children}</main>
    </div>
  );
}

export function Card({
  className,
  children,
  ...props
}: PropsWithChildren<HTMLAttributes<HTMLDivElement>>) {
  return (
    <div className={["remoteos-card", className].filter(Boolean).join(" ")} {...props}>
      {children}
    </div>
  );
}

export function SectionTitle({
  title,
  detail
}: {
  title: string;
  detail?: string;
}) {
  return (
    <div className="remoteos-section-title">
      <h2>{title}</h2>
      {detail ? <span>{detail}</span> : null}
    </div>
  );
}

export function Pill({
  tone = "neutral",
  children
}: PropsWithChildren<{ tone?: "neutral" | "success" | "warning" | "danger" }>) {
  return <span className={`remoteos-pill remoteos-pill--${tone}`}>{children}</span>;
}

export function EmptyState({
  title,
  detail,
  action
}: {
  title: string;
  detail: string;
  action?: React.ReactNode;
}) {
  return (
    <Card className="remoteos-empty-state">
      <h3>{title}</h3>
      <p>{detail}</p>
      {action ? <div>{action}</div> : null}
    </Card>
  );
}

export const remoteOsStyles = `
  .remoteos-shell {
    display: flex;
    min-height: 100dvh;
    flex-direction: column;
    padding: 24px 18px 120px;
    background:
      radial-gradient(circle at top, rgba(131, 209, 196, 0.2), transparent 32%),
      linear-gradient(180deg, #07131f 0%, #0f2235 50%, #081119 100%);
    color: #f3f8fb;
    font-family: "SF Pro Display", "SF Pro Text", ui-sans-serif, system-ui, sans-serif;
  }

  .remoteos-shell__header {
    display: grid;
    gap: 8px;
    margin-bottom: 20px;
  }

  .remoteos-shell__eyebrow {
    margin: 0;
    font-size: 0.72rem;
    letter-spacing: 0.18em;
    text-transform: uppercase;
    color: #8cc8bd;
  }

  .remoteos-shell__header h1 {
    margin: 0;
    font-size: clamp(2rem, 6vw, 3rem);
    line-height: 1;
  }

  .remoteos-shell__subtitle {
    margin: 0;
    max-width: 38rem;
    color: rgba(243, 248, 251, 0.72);
  }

  .remoteos-shell__main {
    display: grid;
    gap: 16px;
  }

  .remoteos-card {
    border: 1px solid rgba(243, 248, 251, 0.08);
    border-radius: 24px;
    background: rgba(4, 15, 24, 0.74);
    box-shadow: 0 20px 40px rgba(0, 0, 0, 0.22);
    backdrop-filter: blur(18px);
  }

  .remoteos-section-title {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 12px;
  }

  .remoteos-section-title h2 {
    margin: 0;
    font-size: 1rem;
  }

  .remoteos-section-title span {
    color: rgba(243, 248, 251, 0.68);
    font-size: 0.86rem;
  }

  .remoteos-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    border-radius: 999px;
    padding: 0.28rem 0.72rem;
    font-size: 0.75rem;
    font-weight: 600;
    background: rgba(255, 255, 255, 0.08);
  }

  .remoteos-pill--success {
    background: rgba(48, 207, 144, 0.18);
    color: #8ef2c2;
  }

  .remoteos-pill--warning {
    background: rgba(242, 198, 74, 0.18);
    color: #f7d676;
  }

  .remoteos-pill--danger {
    background: rgba(240, 89, 89, 0.18);
    color: #ffaaaa;
  }

  .remoteos-empty-state {
    display: grid;
    gap: 10px;
    padding: 22px;
  }

  .remoteos-empty-state h3,
  .remoteos-empty-state p {
    margin: 0;
  }

  .remoteos-empty-state p {
    color: rgba(243, 248, 251, 0.72);
  }
`;
