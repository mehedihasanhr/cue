import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Cue Studio's web side: its own root, sharing Cue's node_modules and UI kit
// (`../src/ui`, `../src/styles`).
export default defineConfig({
  root: __dirname,
  plugins: [react()],
  clearScreen: false,
  server: { port: 1430, strictPort: true, fs: { allow: [".."] }, watch: { ignored: ["**/src-tauri/**"] } },
  build: { outDir: "dist", emptyOutDir: true, target: "chrome110" },
});
