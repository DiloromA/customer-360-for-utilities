// Declarative source of truth for the left nav rail. Adding an item is one
// entry here — NavRail and App.tsx just iterate this list.
import {
  Map,
  Smile,
  Headset,
  ZapOff,
  CircleDollarSign,
  Leaf,
  Waypoints,
  BookOpen,
  Gauge,
  type LucideIcon,
} from "lucide-react";

export type NavGroup = "top" | "business" | "reference";

export interface NavItem {
  id: string;
  label: string;
  icon: LucideIcon;
  group: NavGroup;
  status: "ready" | "placeholder";
  // Shown on the PlaceholderView card for items not yet built.
  blurb?: string;
}

export const NAV_ITEMS: NavItem[] = [
  { id: "explorer", label: "Explorer", icon: Map, group: "top", status: "ready" },

  {
    id: "csat", label: "CSAT", icon: Smile,
    group: "business", status: "ready",
    blurb: "Customer satisfaction: CSAT trend, complaint volume and themes, and per-customer complaint-risk scores for targeted outreach.",
  },
  {
    id: "customer-service", label: "Customer Service", icon: Headset,
    group: "business", status: "placeholder",
    blurb: "Customer-service console: search to a full customer profile with active-outage status and next-best-action insights.",
  },
  {
    id: "outage-reliability", label: "Outages & Reliability", icon: ZapOff,
    group: "business", status: "placeholder",
    blurb: "Ops view: active-outage incidents, reliability metrics, and major-event days.",
  },
  {
    id: "revenue-collections", label: "Revenue & Collections", icon: CircleDollarSign,
    group: "business", status: "placeholder",
    blurb: "Credit & collections: payment-stress cohorts, arrears, and LIHEAP-eligible outreach.",
  },
  {
    id: "ee-der-programs", label: "EE & DER Programs", icon: Leaf,
    group: "business", status: "placeholder",
    blurb: "Energy-efficiency & DER: EV/heat-pump/solar detection, program fit, and enrollment gaps.",
  },

  {
    id: "data-model", label: "Data Model", icon: Waypoints,
    group: "reference", status: "ready",
  },
  {
    id: "documentation", label: "Documentation", icon: BookOpen,
    group: "reference", status: "ready",
  },
  {
    id: "metrics-catalog", label: "Metrics Catalog", icon: Gauge,
    group: "reference", status: "ready",
  },
];

export const GROUP_LABEL: Record<NavGroup, string> = {
  top: "Overview",
  business: "Service & Experience",
  reference: "Reference",
};

export const DEFAULT_VIEW = "explorer";
