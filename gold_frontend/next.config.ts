import type { NextConfig } from "next";

// Browser requests stay on /api. API_BASE_URL is only the server-side rewrite
// target when a reverse proxy does not route /api directly to Phoenix.
const nextConfig: NextConfig = {
  reactStrictMode: true,
  async rewrites() {
    return [
      {
        source: "/api/:path*",
        destination: `${(process.env.API_BASE_URL || "https://api-crypto.9nine.tech").replace(/\/$/, "")}/api/:path*`,
      },
    ];
  },
};

export default nextConfig;
