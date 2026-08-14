import { useState, type ReactNode } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import {
  Compass, Boxes, AppWindow, Headset, ZapOff, CircleDollarSign, Leaf,
  type LucideIcon,
} from "lucide-react";
import overviewDoc from "../docs/overview.md?raw";
import dataModelDoc from "../docs/data-model.md?raw";
import appArchDoc from "../docs/app-architecture.md?raw";
import ucCustomerServiceDoc from "../docs/usecase-customer-service.md?raw";
import ucOutageDoc from "../docs/usecase-outage-reliability.md?raw";
import ucRevenueDoc from "../docs/usecase-revenue-collections.md?raw";
import ucEeDerDoc from "../docs/usecase-ee-der.md?raw";

// In-app technical documentation: concise technical writing on the data model, the app
// architecture, and the use cases / business value linked to each business
// unit. Content is plain markdown; cross-links use a `doc:<id>` scheme to
// switch topics in place and an `app:<view>` scheme to jump to a live surface
// (see linkComponents below).
type DocGroupId = "solution" | "use-cases";

interface DocTopic {
  id: string;
  label: string;
  icon: LucideIcon;
  content: string;
  group: DocGroupId;
}

const TOPICS: DocTopic[] = [
  { id: "overview", label: "Overview", icon: Compass, content: overviewDoc, group: "solution" },
  { id: "data-model", label: "The data model", icon: Boxes, content: dataModelDoc, group: "solution" },
  { id: "app-architecture", label: "Application architecture", icon: AppWindow, content: appArchDoc, group: "solution" },

  { id: "usecase-customer-service", label: "Customer Service", icon: Headset, content: ucCustomerServiceDoc, group: "use-cases" },
  { id: "usecase-outage-reliability", label: "Outages & Reliability", icon: ZapOff, content: ucOutageDoc, group: "use-cases" },
  { id: "usecase-revenue-collections", label: "Revenue & Collections", icon: CircleDollarSign, content: ucRevenueDoc, group: "use-cases" },
  { id: "usecase-ee-der", label: "EE & DER Programs", icon: Leaf, content: ucEeDerDoc, group: "use-cases" },
];

const GROUPS: { id: DocGroupId; label: string }[] = [
  { id: "solution", label: "The solution" },
  { id: "use-cases", label: "Use cases & business value" },
];

export function DocumentationView({
  onOpenDataModel,
  onOpenMetricsCatalog,
}: {
  onOpenDataModel: () => void;
  onOpenMetricsCatalog: () => void;
}) {
  const [activeId, setActiveId] = useState(TOPICS[0].id);
  const active = TOPICS.find((p) => p.id === activeId) ?? TOPICS[0];

  // Handle the custom link schemes used inside the markdown prose:
  //   doc:<topic-id>  → switch the active topic in-place
  //   app:<view>      → jump out to a live app surface
  const handleDocLink = (href: string) => {
    if (href.startsWith("doc:")) {
      const id = href.slice(4);
      if (TOPICS.some((p) => p.id === id)) setActiveId(id);
    } else if (href === "app:data-model") {
      onOpenDataModel();
    } else if (href === "app:metrics-catalog") {
      onOpenMetricsCatalog();
    }
  };

  const linkComponents = {
    a({ node: _node, href, children, ...props }: { node?: unknown; href?: string; children?: ReactNode }) {
      if (href && (href.startsWith("doc:") || href.startsWith("app:"))) {
        return (
          <button type="button" className="doc-inline-link" onClick={() => handleDocLink(href)}>
            {children}
          </button>
        );
      }
      return (
        <a href={href} target="_blank" rel="noreferrer" {...props}>
          {children}
        </a>
      );
    },
  };

  return (
    <div className="documentation-view">
      <nav className="doc-toc">
        {GROUPS.map((g) => {
          const items = TOPICS.filter((t) => t.group === g.id);
          if (items.length === 0) return null;
          return (
            <div key={g.id} className="doc-toc-group">
              <div className="doc-toc-group-label">{g.label}</div>
              {items.map((t) => (
                <button
                  key={t.id}
                  type="button"
                  className={`doc-toc-item${t.id === activeId ? " active" : ""}`}
                  onClick={() => setActiveId(t.id)}
                >
                  <t.icon size={15} />
                  <span>{t.label}</span>
                </button>
              ))}
            </div>
          );
        })}
      </nav>
      <div className="doc-content card">
        <ReactMarkdown remarkPlugins={[remarkGfm]} components={linkComponents}>
          {active.content}
        </ReactMarkdown>
      </div>
    </div>
  );
}
