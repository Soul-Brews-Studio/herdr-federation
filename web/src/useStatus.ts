import { useEffect, useState } from "react";
import { api } from "./api";
import { useSettings } from "./settings";
import type { Status } from "./types";

/** One poller, shared by both pages. A relay restart just skips a tick. */
export function useStatus(override?: number) {
  const [settings] = useSettings();
  const intervalMs = override ?? settings.pollMs;
  const [status, setStatus] = useState<Status | null>(null);

  useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const next = await api.status();
        if (alive) setStatus(next);
      } catch {
        /* relay restarting */
      }
    };
    void tick();
    const id = setInterval(tick, intervalMs);
    return () => {
      alive = false;
      clearInterval(id);
    };
  }, [intervalMs]);

  return status;
}
