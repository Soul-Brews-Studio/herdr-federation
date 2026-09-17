import { lazy, StrictMode, Suspense } from "react";
import { createRoot } from "react-dom/client";
import { useStatus } from "./useStatus";
import { Console } from "./pages/Console";
import "./index.css";

// the console is the landing view; everything else ships as its own chunk
const Squads = lazy(() => import("./pages/Squads").then((m) => ({ default: m.Squads })));
const Admin = lazy(() => import("./pages/Admin").then((m) => ({ default: m.Admin })));
const JoinLanding = lazy(() => import("./pages/JoinLanding").then((m) => ({ default: m.JoinLanding })));

const Loading = () => <div className="grid h-full place-content-center text-[11px] text-faint">…</div>;

function App() {
  const status = useStatus();
  const path = location.pathname;

  if (path.startsWith("/admin"))
    return (
      <Suspense fallback={<Loading />}>
        <Admin />
      </Suspense>
    );

  if (path.startsWith("/join"))
    return (
      <Suspense fallback={<Loading />}>
        <JoinLanding status={status} />
      </Suspense>
    );

  if (path.startsWith("/teams"))
    return (
      <Suspense fallback={<Loading />}>
        <Squads status={status} />
      </Suspense>
    );

  return <Console status={status} />;
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
