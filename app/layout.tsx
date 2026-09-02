import type { Metadata } from 'next'
import { Inter } from 'next/font/google'
import './globals.css'

const inter = Inter({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-inter',
})

export const metadata: Metadata = {
  title: 'Welkin — The control plane for economic events',
  description: 'A configuration and composition layer for event-driven economic processing and archival.',
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en" className={`bg-background ${inter.variable}`}><body className={inter.className}>{children}</body></html>
}
