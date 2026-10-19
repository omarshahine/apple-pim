import { defineConfig } from "cf/config";

// Static Astro docs site served from Workers static assets (formerly Pages).
export default defineConfig({
	worker: {
		name: "apple-pim",
		compatibilityDate: "2026-10-01",
		domains: ["apple-pim.omarknows.app"],
		workersDev: true,
		assets: {
			// Match the legacy Pages behavior: unknown paths fall back to index.html.
			notFoundHandling: "single-page-application",
		},
	},
});
