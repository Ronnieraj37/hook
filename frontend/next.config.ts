import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // In production Vercel serves api/backtest.py itself. In `next dev`, forward to the local Python server
  // (npm run dev:api) so the same URL works.
  async rewrites() {
    if (process.env.NODE_ENV !== "development") return [];
    return [{ source: "/api/backtest", destination: "http://127.0.0.1:8787/api/backtest" }];
  },
};

export default nextConfig;
