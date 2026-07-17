import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  root: "client",
  build: {
    outDir: "../dist",
    emptyOutDir: true,
    // The mapping stack is large; split the heavy libs into their own
    // long-lived, cacheable chunks instead of one ~2.8 MB bundle. Matched by
    // module path (react-map-gl exposes only subpaths, so it can't be named
    // as a package entry in the object form of manualChunks).
    chunkSizeWarningLimit: 2000,
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (!id.includes("node_modules")) return;
          if (/@(deck|luma|math|loaders)\.gl/.test(id)) return "vendor-deck";
          if (/maplibre-gl|react-map-gl|@vis\.gl/.test(id)) return "vendor-maplibre";
          if (/recharts|d3-/.test(id)) return "vendor-charts";
          if (/node_modules[\\/](react|react-dom|scheduler)[\\/]/.test(id)) return "vendor-react";
        },
      },
    },
  },
});
