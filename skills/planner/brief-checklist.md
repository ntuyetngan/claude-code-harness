# Brief checklist

A complete brief answers every row. The skill fills what it can from the ticket, the Sentry issue and a short read of the code, then asks the user for the rest in one batch. It never invents an answer for a row.

| # | Field | What it answers | Fill from | If still missing |
| --- | --- | --- | --- | --- |
| 1 | Intent | The larger task this serves, who it is for, what the output enables | Ticket description, parent issue, Sentry impact | Ask. Motivation changes what "minimal" means. |
| 2 | Goal | One sentence: what is different when this is done | Ticket title, ask text | Ask, offer your restatement first |
| 3 | Expected output | The deliverables, one line each: code path, behavior, test, docs page | Ticket, sibling feature | Ask |
| 4 | Done when | The observable proof: test names, build, screenshot, endpoint response | Ticket acceptance criteria, existing tests | Ask. Without it "done" is a guess. |
| 5 | Where to look | Entry points, files, the pattern to mirror ("how we did X") | Short read, git log of the area, docs page | Ask only if the read found two candidates or none |
| 6 | Constraints | Invariants that must hold, "don't break Z", flags, currencies, timezones, privacy rules | Repo rules, docs, ticket | Ask when the area touches payments, auth, permissions, migrations, venue privacy, legacy |
| 7 | Out of scope | Adjacent things noticed and deliberately left alone | Short read | Propose the list, ask to confirm. Default is out. |
| 8 | Approaches to avoid | Naive or rejected solutions, abstractions the user has pushed back on before | Memory, ticket comments, PR history | Ask when two viable designs exist |
| 9 | Examples | Concrete inputs and expected outputs, or a reproduction for a bug | Ticket, Sentry event, existing tests | Ask for one example when behavior is not obvious from the code |
| 10 | Risk level | Small and local, or cross-cutting (payments, auth, schema, data deletion, concurrency, public API) | Short read | Decide from the read; state it in the plan |
| 11 | Size check | Could the diff be described in one sentence? | The ask | If yes, say so and offer to skip the plan |

Rules the checklist enforces, from Anthropic's prompting guidance and Osmani's workflow notes:

- Specify the whole task in the first turn. Details dripped across turns cost tokens and cause missed surfaces.
- Say what to do, not what not to do. Convert every "don't" into the positive behavior the plan should show.
- Give the reason, not only the request. Intent lets the implementer connect the task to the right code.
- State scope breadth explicitly per surface ("every performers section, not only the first"), since models follow instructions literally.
- Give a check the implementer can run. A plan without a runnable proof is a plan that ends in "looks done".
- Ask rather than assume. Models propagate an early wrong assumption into the whole feature; the plan lists its assumptions and each one is confirmed or verified.
- Prefer the simplest thing that works. Before accepting any helper, abstraction, flag or fallback in the plan, ask "couldn't you just…?" and keep the simpler version unless the constraints forbid it.
