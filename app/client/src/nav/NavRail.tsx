import { useState } from "react";
import { PanelLeftClose, PanelLeftOpen } from "lucide-react";
import { NAV_ITEMS, GROUP_LABEL, type NavGroup } from "./navConfig";

const GROUPS: NavGroup[] = ["top", "business", "reference"];

export function NavRail({
  activeView, onSelect, collapsed, onToggleCollapsed,
}: {
  activeView: string;
  onSelect: (id: string) => void;
  collapsed: boolean;
  onToggleCollapsed: () => void;
}) {
  // Collapsed mode is icon-only, so a fast custom tooltip stands in for the
  // hidden text label. `position: fixed`, computed from the hovered/focused
  // button's own rect, so it isn't clipped by the rail's `overflow-x: hidden`
  // (an absolutely-positioned child confined to the ~64px collapsed rail
  // would be).
  const [tooltip, setTooltip] = useState<{ label: string; top: number; left: number } | null>(null);

  const showTooltip = (label: string, el: HTMLElement) => {
    if (!collapsed) return;
    const rect = el.getBoundingClientRect();
    setTooltip({ label, top: rect.top + rect.height / 2, left: rect.right + 8 });
  };
  const hideTooltip = () => setTooltip(null);

  return (
    <nav className={`nav-rail${collapsed ? " collapsed" : ""}`} aria-label="Primary">
      <button
        type="button"
        className="nav-collapse-toggle"
        onClick={onToggleCollapsed}
        aria-expanded={!collapsed}
        aria-label={collapsed ? "Expand navigation" : "Collapse navigation"}
        title={collapsed ? "Expand navigation (Ctrl/Cmd+B)" : "Collapse navigation (Ctrl/Cmd+B)"}
      >
        {collapsed ? <PanelLeftOpen size={18} /> : <PanelLeftClose size={18} />}
      </button>

      {GROUPS.map((group) => {
        const items = NAV_ITEMS.filter((i) => i.group === group);
        const label = GROUP_LABEL[group];
        return (
          <div key={group} className={`nav-group nav-group-${group}`}>
            {!collapsed && <div className="nav-group-label">{label}</div>}
            {items.map((item) => {
              const Icon = item.icon;
              const isActive = item.id === activeView;
              return (
                <button
                  key={item.id}
                  type="button"
                  className={`nav-item${isActive ? " active" : ""}`}
                  onClick={() => onSelect(item.id)}
                  onMouseEnter={(e) => showTooltip(item.label, e.currentTarget)}
                  onMouseLeave={hideTooltip}
                  onFocus={(e) => showTooltip(item.label, e.currentTarget)}
                  onBlur={hideTooltip}
                  aria-current={isActive ? "page" : undefined}
                  aria-label={item.label}
                >
                  <Icon size={20} className="nav-item-icon" />
                  {!collapsed && <span className="nav-item-label">{item.label}</span>}
                </button>
              );
            })}
          </div>
        );
      })}

      {tooltip && (
        <div className="nav-item-tooltip" role="tooltip" style={{ top: tooltip.top, left: tooltip.left }}>
          {tooltip.label}
        </div>
      )}
    </nav>
  );
}
