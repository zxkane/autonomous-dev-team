# Design Canvas — Detailed Reference

Loaded from `SKILL.md` Step 1 when a design canvas is needed and the IDE supports Pencil MCP, or when a markdown-only canvas needs more structure than the inline template.

## Pencil MCP workflow (Claude Code with Pencil MCP installed)

1. **Check editor state**: call `get_editor_state()` to see if a `.pen` file is open.
2. **Open or create design file**: `open_document("docs/designs/<feature>.pen")` or `open_document("new")`.
3. **Get design guidelines** (optional): `get_guidelines(topic="landing-page|table|tailwind|code")`.
4. **Get style guide** for consistent design: `get_style_guide_tags()` then `get_style_guide(tags=[...])`.
5. **Create design elements**: `batch_design(operations)` to create UI mockups, component hierarchy diagrams, data flow visualizations, and architecture diagrams.
6. **Validate design visually**: `get_screenshot()` to verify the design looks correct.
7. **Document design decisions**: add text annotations explaining choices, component specifications, and interaction patterns.

## Markdown-only canvas template

For IDEs without Pencil MCP, create `docs/designs/<feature>.md`:

```
# Design Canvas — <feature>

Feature: <Feature Name>
Date: YYYY-MM-DD
Status: Draft | In Review | Approved

## UI Mockup / Wireframe
<ASCII art, screenshot reference, or link to a Figma frame>

## Component Architecture
<component tree, props/state flow>

## Data Flow Diagram
<API calls, state management>

## Design Notes
- Key decisions
- Accessibility considerations
- Responsive behavior
- Failure modes / edge cases
```

## When to create a design canvas

- New UI components or pages
- Feature implementations with user-facing changes
- Architecture decisions that benefit from visualization
- Complex data flows or state management

Skip the canvas for trivial bug fixes, dependency bumps, or refactors that don't change behavior.

## Design approval

- **Interactive mode**: present the canvas to the user, get explicit approval, document feedback, update status to "Approved."
- **Autonomous mode**: create the canvas doc and proceed immediately — no approval gate.
