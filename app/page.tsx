'use client'

import { useEffect, useState } from 'react'
import {
  ArrowUpRight,
  Box,
  ChevronRight,
  Command,
  GitBranch,
  Layers3,
  Menu,
  Search,
  ShieldCheck,
  Workflow,
  X,
} from 'lucide-react'

const navItems = ['Overview', 'Architecture', 'Evidence']

const pipeline = [
  { icon: GitBranch, eyebrow: 'Input', title: 'Any producer', detail: 'Stripe, HTTP, Kafka' },
  { icon: Workflow, eyebrow: 'Boundary', title: 'OpenMeter Collector', detail: 'Normalize once' },
  { icon: Box, eyebrow: 'Contract', title: 'Canonical CloudEvent', detail: 'The platform event' },
]

function Mark() {
  return <span className="mark" aria-hidden="true"><span /><span /><span /></span>
}

export default function Home() {
  const [paletteOpen, setPaletteOpen] = useState(false)
  const [mobileOpen, setMobileOpen] = useState(false)

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault()
        setPaletteOpen(true)
      }
      if (event.key === 'Escape') setPaletteOpen(false)
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  const goTo = (id: string) => {
    setPaletteOpen(false)
    document.getElementById(id)?.scrollIntoView({ behavior: 'smooth' })
  }

  return (
    <main id="top" className="site-shell">
      <header className="site-header">
        <a className="brand" href="#top" aria-label="Welkin home"><Mark /><span>welkin</span></a>
        <nav className="desktop-nav" aria-label="Primary navigation">
          {navItems.map((item, index) => <a key={item} href={`#${['top', 'architecture', 'evidence'][index]}`}>{item}</a>)}
        </nav>
        <div className="header-actions">
          <button className="search-trigger" onClick={() => setPaletteOpen(true)} aria-label="Open command menu"><Search data-icon="inline-start" /><span>Search</span><kbd>⌘ K</kbd></button>
          <button className="menu-trigger" onClick={() => setMobileOpen(!mobileOpen)} aria-label="Toggle navigation">{mobileOpen ? <X /> : <Menu />}</button>
          <a className="header-link" href="#evidence">Read the brief <ArrowUpRight data-icon="inline-end" /></a>
        </div>
      </header>

      {mobileOpen && <nav className="mobile-nav" aria-label="Mobile navigation">{navItems.map((item, index) => <a key={item} href={`#${['top', 'architecture', 'evidence'][index]}`} onClick={() => setMobileOpen(false)}>{item}<ChevronRight /></a>)}</nav>}

      <section className="hero">
        <div className="eyebrow"><span className="status-dot" /> Architecture in progress <span className="eyebrow-divider">/</span> Gate 1 partial</div>
        <h1>The control plane<br />for economic events.</h1>
        <p className="hero-copy">Welkin is the configuration and composition layer for event-driven economic processing and archival.</p>
        <div className="hero-actions"><button className="primary-button" onClick={() => setPaletteOpen(true)}><Command data-icon="inline-start" /> Explore Welkin <kbd>⌘ K</kbd></button><a className="text-button" href="#architecture">See the architecture <ArrowUpRight data-icon="inline-end" /></a></div>
        <div className="hero-meta"><span>OPEN SOURCE ARCHITECTURE</span><span>V0.1 / PROPOSED</span></div>
      </section>

      <section id="architecture" className="architecture section-rule">
        <div className="section-heading"><div><div className="section-index">01</div><h2>One event.<br />Two independent planes.</h2></div><p>Canonicalize once at the<br />Collector boundary.</p></div>
        <div className="pipeline" aria-label="Welkin event pipeline">
          {pipeline.map((item, index) => { const Icon = item.icon; return <div className="pipeline-step" key={item.title}><div className="pipeline-card"><div className="icon-box"><Icon /></div><div><div className="card-eyebrow">{item.eyebrow}</div><h3>{item.title}</h3><p>{item.detail}</p></div></div>{index < pipeline.length - 1 && <ChevronRight className="pipeline-arrow" />}</div> })}
        </div>
        <div className="planes"><article className="plane-card economic"><div className="plane-top"><span className="plane-icon"><Layers3 /></span><span>Economic Plane</span><span className="plane-state">independent</span></div><h3>Usage becomes revenue.</h3><p>OpenMeter receives the canonical event and maps it to native Stripe billing. Archive failures never interrupt this path.</p><a href="#evidence">Explore the plane <ArrowUpRight data-icon="inline-end" /></a></article><article className="plane-card archive"><div className="plane-top"><span className="plane-icon"><Box /></span><span>Archive Plane</span><span className="plane-state">independent</span></div><h3>Every event remains queryable.</h3><p>The broker routes the same event to object storage, where it becomes durable Parquet without touching economic processing.</p><a href="#evidence">Explore the plane <ArrowUpRight data-icon="inline-end" /></a></article></div>
      </section>

      <section id="evidence" className="evidence section-rule"><div className="section-heading"><div><div className="section-index">02</div><h2>Built in public.<br />Evidence over theatre.</h2></div><p>What is known, what is next,<br />and nothing invented.</p></div><div className="evidence-list"><div className="evidence-row"><div><span className="row-kicker">Gate 1</span><h3>Architecture and operating model</h3><p>Boundary, planes, and canonical contract documented.</p></div><span className="badge partial">Partial</span></div><div className="evidence-row"><div><span className="row-kicker">Gate 2</span><h3>Runtime evidence</h3><p>Ingestion, billing, and archive paths verified end to end.</p></div><span className="badge next">Next</span></div><div className="evidence-row"><div><span className="row-kicker">Principle</span><h3>No fabricated metrics</h3><p>Welkin only surfaces evidence the system has actually produced.</p></div><ShieldCheck className="row-check" /></div></div></section>

      <footer className="site-footer"><a className="brand" href="#top"><Mark /><span>welkin</span></a><span>Architecture first. Evidence always.</span></footer>

      {paletteOpen && <div className="palette-backdrop" role="dialog" aria-modal="true" aria-label="Welkin command menu" onClick={() => setPaletteOpen(false)}><div className="palette" onClick={event => event.stopPropagation()}><div className="palette-search"><Search /><input autoFocus placeholder="Search or jump to..." /><kbd>ESC</kbd></div><div className="palette-label">QUICK ACTIONS</div><button onClick={() => goTo('architecture')}><Workflow /><span><strong>Explore canonical flow</strong><small>View Welkin&apos;s event model</small></span><kbd>↵</kbd></button><button onClick={() => goTo('evidence')}><ShieldCheck /><span><strong>Open architecture status</strong><small>Review current evidence</small></span><kbd>↵</kbd></button></div></div>}
    </main>
  )
}
