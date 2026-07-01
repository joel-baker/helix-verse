; Verse indentation queries for Helix editor
; Controls auto-indentation when pressing Enter.
;
; Verse is indentation-sensitive: blocks are introduced by ':' (colon_block),
; '=' followed by INDENT (indented_block), or '{' ... '}' (brace_block).

; ─────────────────────────────────────────────
; Indent triggers
; ─────────────────────────────────────────────

; Brace blocks: { ... }
(brace_block) @indent

; Colon blocks: : INDENT ... DEDENT  (if/for/loop/sync/etc.)
(colon_block) @indent

; Indented blocks: INDENT ... DEDENT  (function bodies after =)
(indented_block) @indent

; ─────────────────────────────────────────────
; Outdent triggers
; ─────────────────────────────────────────────

; Closing brace dedents to match its opening brace
"}" @outdent
