import { useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { Layers, Boxes, Globe, type LucideIcon } from "lucide-react";
import tiersDoc from "../docs/tiers.md?raw";
import starSchemaDoc from "../docs/star-schema.md?raw";
import dataSourcesDoc from "../docs/data-sources.md?raw";

// In-app conceptual guide (design doc §8/§12.1): the demo-facing counterpart
// to the ERD. Content lives in app/client/src/docs/*.md, written for a demo
// viewer rather than a repo extender — see ARCHITECTURE.md for build mechanics.
interface DocPage {
  id: string;
  label: string;
  icon: LucideIcon;
  content: string;
}

const PAGES: DocPage[] = [
  { id: "tiers", label: "Tiers", icon: Layers, content: tiersDoc },
  { id: "star-schema", label: "The Curated Star Schema", icon: Boxes, content: starSchemaDoc },
  { id: "data-sources", label: "Data Sources", icon: Globe, content: dataSourcesDoc },
];

export function DocumentationView({ onOpenDataModel }: { onOpenDataModel: () => void }) {
  const [activeId, setActiveId] = useState(PAGES[0].id);
  const active = PAGES.find((p) => p.id === activeId) ?? PAGES[0];

  return (
    <div className="documentation-view">
      <nav className="doc-toc">
        {PAGES.map((p) => (
          <button
            key={p.id}
            type="button"
            className={`doc-toc-item${p.id === activeId ? " active" : ""}`}
            onClick={() => setActiveId(p.id)}
          >
            <p.icon size={15} />
            <span>{p.label}</span>
          </button>
        ))}
        {active.id === "star-schema" && (
          <button type="button" className="doc-toc-link" onClick={onOpenDataModel}>
            Open the Data Model view →
          </button>
        )}
      </nav>
      <div className="doc-content card">
        <ReactMarkdown remarkPlugins={[remarkGfm]}>{active.content}</ReactMarkdown>
      </div>
    </div>
  );
}
