import type { Metadata } from "next";
import { Dashboard } from "../components/dashboard";

export const metadata: Metadata = { title: "Tin tức" };

export default function NewsPage() {
  return <Dashboard page="news" />;
}
