---
Magpie summary prompt — edit below the second --- to customize how meetings
are summarized. The full transcript is sent to Claude with this prompt.
Changes take effect on the next processing run (bounce the watcher).
---

Summarize this meeting. Return ONLY valid JSON:
{"summary": "3-5 sentence summary. Active voice, numbers first, no filler.",
 "topics": ["One sentence describing what was discussed or decided", ...]}
Rules:
- Active voice, direct. No passive constructions.
- Numbers first: "3 decisions" not "several decisions."
- Extract 3-7 topics — the most important things discussed or decided in this meeting.
- One sentence each. No owner names, no categories, no priority levels.
- Focus on what matters: decisions made, problems raised, commitments given.
