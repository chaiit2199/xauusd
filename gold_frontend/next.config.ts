import type { NextConfig } from "next";

// API_BASE_URL không có tiền tố NEXT_PUBLIC_ nên Next chỉ nhúng giá trị vào
// bundle client khi khai báo ở đây (đọc từ .env.local / môi trường tại lúc build).
const nextConfig: NextConfig = {
  reactStrictMode: true,
  env: {
    API_BASE_URL: process.env.API_BASE_URL ?? "",
  },
};

export default nextConfig;
