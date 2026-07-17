import type { LucideIcon } from "lucide-react";

// Reusable "Coming soon" card for nav destinations not yet built. Keeps the
// nav fully clickable and the demo story coherent without half-built views.
export function PlaceholderView({
  title, icon: Icon, blurb,
}: { title: string; icon: LucideIcon; blurb?: string }) {
  return (
    <div className="placeholder-view">
      <div className="card placeholder-card">
        <Icon size={32} className="placeholder-icon" />
        <div className="placeholder-title">{title}</div>
        {blurb && <p className="placeholder-blurb">{blurb}</p>}
        <span className="badge neutral">Coming soon</span>
      </div>
    </div>
  );
}
