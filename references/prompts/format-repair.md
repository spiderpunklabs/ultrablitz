# Format Repair Prompt — the ONLY non-protocol message sent on a debate thread

Governed by INV-FORMAT-1 (`references/protocol-invariants.md`). `codex-turn`
renders this template with exactly three slots and sends it at most once per
round. It carries no debate-protocol blocks, no plan text, and no critique
content of its own.

Slots (the only interpolations permitted):
- `{EXPECTED_HEADERS}` — the required section headers
- `{CATEGORY_LIST}` — the locked framework categories with their bounds
- `{OFFENDING_OUTPUT}` — the previous response, quoted verbatim (truncated at 4000 chars)

Everything between the fences below is sent as-is after slot substitution.

```
Your previous response did not match the required output shape.

Re-emit that same response in the required shape. Do not change any score,
critique, strength, or verdict content. Do not add or remove critiques. Do not
add commentary about this correction. This is a formatting fix only.

Required section headers, in this order:
{EXPECTED_HEADERS}

The CATEGORY SCORES section must contain exactly these lines, one per category,
each with an integer score within the stated bound:
{CATEGORY_LIST}

Each critique entry starts with its id and severity on one line, in the form
UB-n **[SEVERITY]** summary, and carries all four sub-fields, each on its own line:
   - Category: ...
   - Evidence: ...
   - Impact: ...
   - Suggestion: ...

Your previous response was:
{OFFENDING_OUTPUT}
```
