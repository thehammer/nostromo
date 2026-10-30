# Plan: Ship the plan viewer

This plan adds an in-pane viewer for a job's plan. One paragraph carries *emph-word* text, **strong-word** text, ~~strike-word~~ text and `code-word` inline code.

---

## Background

The plan is a markdown file written by the planner. Today the viewer only shows the checklist; this work shows the whole document, with an outline.

## Goals

- Level one alpha
  - Level two beta
    - Level three gamma
  - Level two delta
- Level one epsilon

### Scope

1. First ordered step
2. Second ordered step
3. Third ordered step

#### Out of scope

Nothing about editing plans.

## Tasks

- [ ] Write the parser
- [x] Write the fixtures
- [ ] Wire the sidebar
- [X] Review the sanitiser
- [ ] Add the outline
- [ ] Ship it
- [x] Celebrate

## Data

| col1 | col2 | col3 | col4 | col5 | col6 | col7 | col8 | col9 | col10 | col11 | col12 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| r1c1 | r1c2 | r1c3 | r1c4 | r1c5 | r1c6 | r1c7 | r1c8 | r1c9 | r1c10 | r1c11 | r1c12 |
| r2c1 | r2c2 | r2c3 | r2c4 | r2c5 | r2c6 | r2c7 | r2c8 | r2c9 | r2c10 | r2c11 | r2c12 |
| r3c1 | r3c2 | r3c3 | r3c4 | r3c5 | r3c6 | r3c7 | r3c8 | r3c9 | r3c10 | r3c11 | r3c12 |

## Config

```yaml
name: plan-viewer
description: 01234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456
steps:
  - parse
  - render
```

## References

### Links

- [the spec](https://example.invalid/spec)
- [local notes](file:///tmp/notes.md)
- [relative spec](docs/spec.md)
- [click me](javascript:alert(1))

![diagram](https://example.invalid/diagram.png)

### Notes

> Measure twice, cut once.

## Rollout `v2` plan

Final paragraph.
