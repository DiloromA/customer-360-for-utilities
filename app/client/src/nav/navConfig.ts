// Declarative source of truth for the left nav rail. Adding an item is one
// entry here — NavRail and App.tsx just iterate this list.
import {
  Map,
  Smile,
  Waypoints,
  BookOpen,
  Gauge,
  type LucideIcon,
} from "lucide-react";

export type NavGroup = "top" | "reference";

export interface NavItem {
  id: string;
  label: string;
  icon: LucideIcon;
  group: NavGroup;
}

// Two groups only: Insights (the live analytical surfaces) and Reference (the
// docs/model/metrics that explain them). The four placeholder business
// functions were retired — their "what this could grow into" story now lives in
// the in-app Documentation.
export const NAV_ITEMS: NavItem[] = [
  { id: "explorer", label: "Explorer", icon: Map, group: "top" },
  { id: "csat", label: "CSAT", icon: Smile, group: "top" },

  { id: "data-model", label: "Data Model", icon: Waypoints, group: "reference" },
  { id: "documentation", label: "Documentation", icon: BookOpen, group: "reference" },
  { id: "metrics-catalog", label: "Metrics Catalog", icon: Gauge, group: "reference" },
];

export const GROUP_LABEL: Record<NavGroup, string> = {
  top: "Insights",
  reference: "Reference",
};

export const DEFAULT_VIEW = "explorer";
