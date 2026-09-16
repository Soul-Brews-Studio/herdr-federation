import { useEffect, useState } from "react";

/**
 * Console preferences. Stored per browser, not per node — the same fleet looks
 * different on a phone and on a desk, and that is the point.
 */
export type Settings = {
  /** what a click on an agent does */
  openIn: "tab" | "replace" | "window";
  /** which renderer a newly opened pane uses */
  render: "text" | "terminal";
  /** terminal mode always accepts typing; this is for the text mirror */
  typeInText: boolean;
  /** pane type size, in px, per renderer */
  zoom: number;
  zoomDense: number;
  /** show the federation / herdr-calls rail */
  showRail: boolean;
  /** how often the console asks its node for state, in ms */
  pollMs: number;
};

export const DEFAULTS: Settings = {
  openIn: "tab",
  render: "text",
  typeInText: false,
  zoom: 13,
  zoomDense: 11,
  showRail: true,
  pollMs: 2000,
};

const KEY = "fed.settings.v1";

function load(): Settings {
  try {
    // merged over DEFAULTS, so a setting added later appears without wiping the rest
    return { ...DEFAULTS, ...(JSON.parse(localStorage.getItem(KEY) ?? "{}") as Partial<Settings>) };
  } catch {
    return DEFAULTS;
  }
}

/** Changes reach every mounted component, including other tabs of this browser. */
const listeners = new Set<(s: Settings) => void>();
let current = load();

export function setSettings(patch: Partial<Settings>) {
  current = { ...current, ...patch };
  localStorage.setItem(KEY, JSON.stringify(current));
  for (const fn of listeners) fn(current);
}

export const resetSettings = () => setSettings(DEFAULTS);

export function useSettings(): [Settings, (patch: Partial<Settings>) => void] {
  const [s, setS] = useState(current);
  useEffect(() => {
    listeners.add(setS);
    // another tab of the same browser edited them
    const onStorage = (e: StorageEvent) => {
      if (e.key === KEY) {
        current = load();
        setS(current);
      }
    };
    addEventListener("storage", onStorage);
    return () => {
      listeners.delete(setS);
      removeEventListener("storage", onStorage);
    };
  }, []);
  return [s, setSettings];
}
