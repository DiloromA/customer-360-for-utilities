import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ReactFlow, ReactFlowProvider, Background, Controls, MiniMap, Handle, Position,
  MarkerType, useReactFlow,
  type Node, type Edge, type NodeProps,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import dagre from "@dagrejs/dagre";
import { KeyRound, Link2, ExternalLink, RotateCcw } from "lucide-react";

// The dynamic ERD: a live entity-relationship diagram over
// Unity Catalog metadata, served by GET /api/data-model/erd. The curated star
// is selected as a layer (its dim_/fact_/bridge_ role prefixes together), not
// a single naming prefix; raw_/ml_/app_ each select by their own prefix.
// Declaring FOREIGN KEY constraints table by table is ongoing; the
// server marks each edge `inferred` per-edge (declared → solid,
// convention-guessed → dashed) and sets the top-level `edgesAreInferred`
// while any edge is still convention-inferred, which drives the banner below.

interface ErdColumn {
  name: string;
  type: string;
  nullable: boolean;
  comment: string | null;
  isPk: boolean;
  isFk: boolean;
  refTable: string | null;
  refColumn: string | null;
}
type ErdKind = "dim" | "fact" | "bridge" | "history" | "other";
interface ErdTable {
  name: string;
  kind: ErdKind;
  comment: string | null;
  ucUrl: string;
  columns: ErdColumn[];
}
interface ErdEdgeData {
  fromTable: string;
  fromColumn: string;
  toTable: string;
  toColumn: string;
  inferred: boolean;
}
type Layer = "curated" | "raw" | "ml" | "app";
interface ErdResponse {
  catalog: string;
  schema: string;
  layer: Layer;
  generatedAt: string;
  edgesAreInferred: boolean;
  tables: ErdTable[];
  edges: ErdEdgeData[];
}

const LAYER_OPTIONS: { value: Layer; label: string }[] = [
  { value: "curated", label: "Curated star" },
  { value: "raw", label: "Raw" },
  { value: "ml", label: "ML" },
  { value: "app", label: "App" },
];
const NODE_WIDTH = 260;
const ROW_HEIGHT = 22;
const HEADER_HEIGHT = 38;

function keyColumns(t: ErdTable): ErdColumn[] {
  return t.columns.filter((c) => c.isPk || c.isFk);
}

// Collapsed default: PK/FK columns only (the structurally relevant ones for
// an ERD) plus a "+N more" toggle row. Expanded shows every column.
function nodeHeight(t: ErdTable, expanded: boolean): number {
  const key = keyColumns(t).length;
  const rest = t.columns.length - key;
  const rows = expanded ? t.columns.length : key + (rest > 0 ? 1 : 0);
  return HEADER_HEIGHT + Math.max(rows, 1) * ROW_HEIGHT + 10;
}

function layoutPositions(
  tables: ErdTable[], edges: ErdEdgeData[], expanded: Set<string>,
): Map<string, { x: number; y: number }> {
  const g = new dagre.graphlib.Graph();
  g.setGraph({ rankdir: "LR", nodesep: 36, ranksep: 110 });
  g.setDefaultEdgeLabel(() => ({}));
  for (const t of tables) {
    g.setNode(t.name, { width: NODE_WIDTH, height: nodeHeight(t, expanded.has(t.name)) });
  }
  for (const e of edges) {
    if (e.fromTable !== e.toTable) g.setEdge(e.fromTable, e.toTable);
  }
  dagre.layout(g);
  const positions = new Map<string, { x: number; y: number }>();
  for (const t of tables) {
    const n = g.node(t.name);
    positions.set(t.name, { x: n.x - n.width / 2, y: n.y - n.height / 2 });
  }
  return positions;
}

// A type alias (not an interface) is required here — interfaces don't
// satisfy Node's `Record<string, unknown>` data constraint in TS.
type TableNodeData = {
  table: ErdTable;
  expanded: boolean;
  onToggleExpanded: (name: string) => void;
};
type TableNodeType = Node<TableNodeData, "table">;

function TableNode({ data }: NodeProps<TableNodeType>) {
  const { table, expanded, onToggleExpanded } = data;
  const key = keyColumns(table);
  const rest = table.columns.filter((c) => !c.isPk && !c.isFk);
  const shown = expanded ? table.columns : key;

  return (
    <div className={`erd-node erd-node-${table.kind}`}>
      <Handle type="target" position={Position.Left} />
      <Handle type="source" position={Position.Right} />
      <div className="erd-node-header" title={table.comment ?? table.name}>
        <span className="erd-node-name">{table.name}</span>
        <a
          className="erd-node-link"
          href={table.ucUrl}
          target="_blank"
          rel="noreferrer"
          title="Open in Unity Catalog"
          onClick={(e) => e.stopPropagation()}
        >
          <ExternalLink size={12} />
        </a>
      </div>
      <div className="erd-node-columns">
        {shown.map((c) => (
          <div
            key={c.name}
            className="erd-node-col"
            title={`${c.type}${c.nullable ? "" : " · NOT NULL"}${c.comment ? ` — ${c.comment}` : ""}`}
          >
            <span className="erd-col-glyph">
              {c.isPk ? <KeyRound size={11} /> : c.isFk ? <Link2 size={11} /> : null}
            </span>
            <span className="erd-col-name">{c.name}</span>
            <span className="erd-col-type">{c.type}</span>
          </div>
        ))}
        {rest.length > 0 && (
          <button type="button" className="erd-node-toggle" onClick={() => onToggleExpanded(table.name)}>
            {expanded ? "Show fewer columns" : `+${rest.length} more column${rest.length === 1 ? "" : "s"}`}
          </button>
        )}
      </div>
    </div>
  );
}

const nodeTypes = { table: TableNode };

function DataModelInner() {
  const [layer, setLayer] = useState<Layer>("curated");
  const [showHistory, setShowHistory] = useState(false);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [erd, setErd] = useState<ErdResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const { fitView } = useReactFlow();

  const load = useCallback(async (refresh?: boolean) => {
    setLoading(true);
    setError(null);
    try {
      const qs = `layer=${encodeURIComponent(layer)}${refresh ? "&refresh=1" : ""}`;
      const resp = await fetch(`/api/data-model/erd?${qs}`);
      const data = await resp.json();
      if (!resp.ok || data.error) throw new Error(data.error || `Request failed (${resp.status})`);
      setErd(data as ErdResponse);
      setExpanded(new Set());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [layer]);

  useEffect(() => { load(); }, [load]);

  const toggleExpanded = useCallback((name: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name); else next.add(name);
      return next;
    });
  }, []);

  // Core star (dim/fact/bridge) is always shown; SCD2 history is an opt-in
  // toggle (a 46-table schema is too much at once). The
  // history classification is curated-star-specific — raw_/ml_/app_ layers
  // show every table unconditionally.
  const visibleTables = useMemo(() => {
    if (!erd) return [];
    if (erd.layer !== "curated") return erd.tables;
    return erd.tables.filter((t) => (t.kind === "history" ? showHistory : true));
  }, [erd, showHistory]);

  const visibleEdges = useMemo(() => {
    if (!erd) return [];
    const names = new Set(visibleTables.map((t) => t.name));
    return erd.edges.filter((e) => names.has(e.fromTable) && names.has(e.toTable));
  }, [erd, visibleTables]);

  const { nodes, edges } = useMemo(() => {
    const positions = layoutPositions(visibleTables, visibleEdges, expanded);
    const nodesOut: TableNodeType[] = visibleTables.map((t) => ({
      id: t.name,
      type: "table",
      position: positions.get(t.name) ?? { x: 0, y: 0 },
      data: { table: t, expanded: expanded.has(t.name), onToggleExpanded: toggleExpanded },
    }));
    const edgesOut: Edge[] = visibleEdges.map((e, i) => ({
      id: `${e.fromTable}.${e.fromColumn}-${e.toTable}.${e.toColumn}-${i}`,
      source: e.fromTable,
      target: e.toTable,
      label: e.fromColumn,
      style: { stroke: "var(--text-muted)", strokeDasharray: e.inferred ? "4 4" : undefined },
      labelStyle: { fill: "var(--text-muted)", fontSize: 10 },
      labelBgStyle: { fill: "var(--panel)" },
      markerEnd: { type: MarkerType.ArrowClosed, color: "var(--text-muted)" },
    }));
    return { nodes: nodesOut, edges: edgesOut };
  }, [visibleTables, visibleEdges, expanded, toggleExpanded]);

  // Re-fit when the table set changes — a layer switch (reloads `erd`) or the
  // SCD2-history toggle. Deliberately NOT on `nodes`: expanding a table's
  // columns changes `nodes` but should leave the camera where the user put it,
  // rather than zooming back out to fit the whole diagram.
  useEffect(() => {
    if (nodes.length === 0) return;
    const id = requestAnimationFrame(() => fitView({ padding: 0.2, duration: 200 }));
    return () => cancelAnimationFrame(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [erd, showHistory, fitView]);

  if (loading && !erd) return <div className="loading">Loading data model…</div>;
  if (error) return <div className="error">{error}</div>;
  if (!erd || erd.tables.length === 0) return <div className="empty-state">No tables found for this layer.</div>;

  return (
    <div className="data-model-view">
      <div className="data-model-toolbar">
        <label className="data-model-field">
          <span>Layer</span>
          <select value={layer} onChange={(e) => setLayer(e.target.value as Layer)}>
            {LAYER_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
          </select>
        </label>
        {layer === "curated" && (
          <label className="data-model-toggle">
            <input type="checkbox" checked={showHistory} onChange={(e) => setShowHistory(e.target.checked)} /> SCD2 history
          </label>
        )}
        <button
          type="button" className="data-model-action"
          onClick={() => fitView({ padding: 0.2, duration: 200 })} title="Re-fit the view"
        >
          <RotateCcw size={13} /> Re-fit
        </button>
        <button
          type="button" className="data-model-action"
          onClick={() => load(true)} title="Refresh metadata (bypass cache)"
        >
          Refresh
        </button>
      </div>
      {erd.edgesAreInferred && (
        <div className="data-model-banner">
          Solid edges are declared foreign keys; dashed edges are inferred from naming convention where a foreign key isn't declared yet.
        </div>
      )}
      <div className="data-model-canvas">
        <ReactFlow
          nodes={nodes}
          edges={edges}
          nodeTypes={nodeTypes}
          nodesDraggable={false}
          fitView
          minZoom={0.1}
          proOptions={{ hideAttribution: true }}
        >
          <Background />
          <Controls showInteractive={false} />
          <MiniMap pannable zoomable />
        </ReactFlow>
      </div>
    </div>
  );
}

export function DataModelView() {
  return (
    <ReactFlowProvider>
      <DataModelInner />
    </ReactFlowProvider>
  );
}
