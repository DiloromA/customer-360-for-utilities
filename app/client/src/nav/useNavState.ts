import { useEffect, useState } from "react";
import { DEFAULT_VIEW } from "./navConfig";

const COLLAPSED_KEY = "c360-nav-collapsed";

// Collapsed follows the theme-persistence precedent (localStorage, default
// expanded). activeView is plain React state — it's not meant to survive a
// reload, only navigation within the session.
export function useNavState() {
  const [collapsed, setCollapsed] = useState<boolean>(
    () => localStorage.getItem(COLLAPSED_KEY) === "1"
  );
  const [activeView, setActiveView] = useState<string>(DEFAULT_VIEW);

  useEffect(() => {
    localStorage.setItem(COLLAPSED_KEY, collapsed ? "1" : "0");
  }, [collapsed]);

  // Ctrl/Cmd+B toggles collapse, matching the rail's own toggle button.
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "b") {
        e.preventDefault();
        setCollapsed((c) => !c);
      }
    }
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, []);

  return {
    collapsed,
    toggleCollapsed: () => setCollapsed((c) => !c),
    activeView,
    setActiveView,
  };
}
