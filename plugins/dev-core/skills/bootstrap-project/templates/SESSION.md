# SESSION.md — <project>

> Durable session log. Survives context compaction; the next session starts by reading the
> latest entry. Newest entry on top. Never write secrets here.
>
> Multi-phase plans go in `ROADMAP.md` **before** the work starts; this file records what
> happened and what is left.

---

## [YYYY-MM-DD] — <short description>

### What was done
- <change> (<PR / commit>)

### Decisions made
<!-- One line each: decision · reason. Accepted WARNING/MEDIUM findings from the merge gate
     go here too: YYYY-MM-DD · finding summary · reason accepted. -->
- <decision> · <reason>

### Pending items for next session
- [ ] <item> (<issue>)

### Requires human attention
- <anything the agent could not or must not do on its own: approvals, credentials, manual checks>
