import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Bonsplit - Native macOS Tab Bar with Split Panes for SwiftUI",
  description: "A native macOS tab bar library with split pane support for SwiftUI applications. Features 120fps animations, drag-and-drop tabs, and full keyboard navigation.",
  openGraph: {
    title: "Bonsplit - Native macOS Tab Bar with Split Panes",
    description: "A native macOS tab bar library with split pane support for SwiftUI. 120fps animations, drag-and-drop, keyboard navigation.",
    images: [
      {
        url: "/og-image.png",
        width: 1200,
        height: 630,
        alt: "Bonsplit Logo",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "Bonsplit - Native macOS Tab Bar with Split Panes",
    description: "A native macOS tab bar library with split pane support for SwiftUI. 120fps animations, drag-and-drop, keyboard navigation.",
    images: ["/og-image.png"],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="dark">
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased bg-black text-white`}
      >
        {children}
      </body>
    </html>
  );
}
