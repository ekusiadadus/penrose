import { defineConfig } from "vite";
import topLevelAwait from "vite-plugin-top-level-await";

// https://vitejs.dev/config/
export default defineConfig({
  build: { target: "esnext" },
  plugins: [topLevelAwait()],
  optimizeDeps: {
    esbuildOptions: { target: "esnext" },
    exclude: ["@penrose/examples", "rose"],
  },
});
