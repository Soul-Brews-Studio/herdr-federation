import { lazy, StrictMode, Suspense } from "react";
import { createRoot } from "react-dom/client";
import { useStatus } from "./useStatus";
import { Console } from "./pages/Console";
import "./index.css";

// the console is the landing view; squads ships as its own chunk
const Squads = lazy(() => import("./pages/Squads").then((m) => ({ default: m.Squads })));

function App() {
  const status = useStatus();
  const squads = location.pathname.startsWith("/teams");
  return squads ? (
    <Suspense fallback={<div className="grid h-full place-content-center text-[11px] text-faint">…</div>}>
      <Squads status={status} />
    </Suspense>
  ) : (
    <Console status={status} />
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
