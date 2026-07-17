// deck.gl ⇄ MapLibre bridge.
//
// Mounts a deck.gl MapboxOverlay as a MapLibre IControl via react-map-gl's
// useControl, so deck layers render *interleaved* with the basemap inside the
// existing <Map> — the basemap, NavigationControl, onMoveEnd bounds logic, and
// the MapErrorBoundary all stay exactly as they were. This is the integration
// mode recommended by deck.gl for react-map-gl + maplibre.
//
// Usage: render <DeckOverlay layers={[...]} /> as a child of <Map>. The overlay
// is created once; setProps on every render keeps its layers/handlers current.

import { useControl } from "react-map-gl/maplibre";
import { MapboxOverlay, type MapboxOverlayProps } from "@deck.gl/mapbox";

export function DeckOverlay(props: MapboxOverlayProps) {
  const overlay = useControl<MapboxOverlay>(() => new MapboxOverlay(props));
  overlay.setProps(props);
  return null;
}
