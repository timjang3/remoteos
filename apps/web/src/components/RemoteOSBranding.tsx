import React from "react";

function joinClasses(...classes: Array<string | undefined>) {
  return classes.filter(Boolean).join(" ");
}

type RemoteOSLogoMarkProps = {
  className?: string;
  decorative?: boolean;
  size?: number;
  title?: string;
};

export function RemoteOSLogoMark({
  className,
  decorative = false,
  size = 44,
  title = "RemoteOS"
}: RemoteOSLogoMarkProps) {
  const accessibilityProps = decorative
    ? { "aria-hidden": true as const }
    : { role: "img" as const, "aria-label": title };

  return (
    <svg
      viewBox="0 0 512 512"
      width={size}
      height={size}
      className={joinClasses("remoteos-logo-mark", className)}
      xmlns="http://www.w3.org/2000/svg"
      {...accessibilityProps}
    >
      <g transform="translate(86 68)">
        <rect
          x="0"
          y="0"
          width="184"
          height="376"
          rx="56"
          fill="var(--logo-phone-shell)"
        />
        <rect
          x="32"
          y="34"
          width="120"
          height="308"
          rx="22"
          fill="var(--logo-phone-screen)"
        />
      </g>
      <g transform="translate(250 194) scale(8.3)">
        <path
          d="M4 3.5C3.8 3.5 3.6 3.6 3.5 3.8C3.4 4 3.4 4.2 3.5 4.4L10 19.5C10.1 19.8 10.4 20 10.7 20C11 20 11.3 19.8 11.4 19.5L13 13L19.5 11.4C19.8 11.3 20 11 20 10.7C20 10.4 19.8 10.1 19.5 10L4.4 3.5C4.3 3.5 4.15 3.5 4 3.5Z"
          fill="var(--logo-cursor)"
          stroke="var(--logo-cursor)"
          strokeWidth="1.2"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </g>
    </svg>
  );
}

type RemoteOSBrandHeaderProps = {
  className?: string;
  subtitle?: React.ReactNode;
  title: string;
};

export function RemoteOSBrandHeader({
  className,
  subtitle,
  title
}: RemoteOSBrandHeaderProps) {
  return (
    <div className={joinClasses("pairing-brand", className)}>
      <div className="pairing-brand-mark">
        <RemoteOSLogoMark decorative className="pairing-brand-logo" />
      </div>
      <h1>{title}</h1>
      {subtitle ? <p>{subtitle}</p> : null}
    </div>
  );
}
