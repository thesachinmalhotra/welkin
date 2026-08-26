## What

<!-- One sentence: what does this PR do? -->

## Why

<!-- Why is this needed? Link to issue or explain the motivation. -->

## How

<!-- How does this work? What changed and why that approach? -->

## Architectural boundary

<!-- Which Welkin boundary does this change touch? (Economic Plane / Archive Plane / Collector / Distribution / Certification / CI / Docs) -->

- [ ] Stays within architectural invariants (see AGENTS.md)
- [ ] No custom machinery where an upstream lego exists
- [ ] No secrets, credentials, or tokens committed

## Verification

<!-- How was this verified? Run the relevant local checks. -->

```bash
# List the commands you ran:
```

- [ ] Local validation passes
- [ ] No references to deleted paths remain
- [ ] Docs updated if applicable

## Checklist

- [ ] Conventional commit messages (`feat:`, `fix:`, `docs:`, etc.)
- [ ] No trailing whitespace, final newline present
- [ ] CUE/YAML/JSON files are valid
- [ ] No `@latest` or unpinned versions introduced
