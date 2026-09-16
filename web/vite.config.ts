import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // one wire contract, shared with the server rather than restated here
  resolve: { alias: { "@wire": fileURLToPath(new URL("../src/wire.ts", import.meta.url)) } },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    rollupOptions: {
      output: {
        // react changes rarely; keep it cacheable and out of the app chunk
        manualChunks: (id) => (id.includes("node_modules/react") ? "react" : undefined),
      },
    },
  },
  server: { fs: { allow: [".."] }, proxy: { "/api": "http://127.0.0.1:6750" } },
});
