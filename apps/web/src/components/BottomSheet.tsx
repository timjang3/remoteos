import React, { useCallback, useEffect, useRef, useState } from "react";

type Props = {
  open: boolean;
  onClose: () => void;
  title: string;
  children: React.ReactNode;
};

export function BottomSheet({ open, onClose, title, children }: Props) {
  const sheetRef = useRef<HTMLDivElement>(null);
  const dragStartY = useRef(0);
  const currentTranslate = useRef(0);
  const isDragging = useRef(false);

  const handleDragStart = useCallback((e: React.TouchEvent) => {
    const touch = e.touches[0];
    if (!touch) return;
    dragStartY.current = touch.clientY;
    currentTranslate.current = 0;
    isDragging.current = true;

    if (sheetRef.current) {
      sheetRef.current.style.transition = "none";
    }
  }, []);

  const handleDragMove = useCallback((e: React.TouchEvent) => {
    if (!isDragging.current) return;
    const touch = e.touches[0];
    if (!touch) return;

    const delta = touch.clientY - dragStartY.current;
    currentTranslate.current = Math.max(0, delta);

    if (sheetRef.current) {
      sheetRef.current.style.transform = `translateY(${currentTranslate.current}px)`;
    }
  }, []);

  const handleDragEnd = useCallback(() => {
    isDragging.current = false;

    if (sheetRef.current) {
      sheetRef.current.style.transition = "";
      sheetRef.current.style.transform = "";
    }

    /* Close if dragged down more than 100px */
    if (currentTranslate.current > 100) {
      onClose();
    }
  }, [onClose]);

  /* Prevent body scroll when open */
  useEffect(() => {
    if (open) {
      document.body.style.overflow = "hidden";
    } else {
      document.body.style.overflow = "";
    }
    return () => {
      document.body.style.overflow = "";
    };
  }, [open]);

  useEffect(() => {
    if (!open) {
      return undefined;
    }

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [onClose, open]);

  return (
    <>
      <div
        className={`sheet-overlay ${open ? "open" : ""}`}
        onClick={onClose}
      />
      <div
        ref={sheetRef}
        className={`sheet ${open ? "open" : ""}`}
        role="dialog"
        aria-modal="true"
        aria-label={title}
      >
        <div
          className="sheet-handle-area"
          onTouchStart={handleDragStart}
          onTouchMove={handleDragMove}
          onTouchEnd={handleDragEnd}
        >
          <div className="sheet-handle" />
        </div>
        <div className="sheet-header">
          <span className="sheet-title">{title}</span>
          <button className="sheet-close" onClick={onClose} aria-label="Close">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
              <path d="M18 6L6 18" />
              <path d="M6 6l12 12" />
            </svg>
          </button>
        </div>
        <div className="sheet-body">
          {children}
        </div>
      </div>
    </>
  );
}
