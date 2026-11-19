# Context-driven docs demos (runbook)

Two scenarios that show Mintlify updating docs from context that lives **outside the codebase**.
Site: https://docs.marcodewey.com (same site as https://mintlify-demo.mintlify.site).
Dashboard: https://dashboard.mintlify.com (org **mintlify-demo**).
Everything here resets nightly at 11 PM Pacific (see "Reset" at the bottom).

| # | Story | Source (what you edit live) | Docs page that changes | Trigger |
|---|---|---|---|---|
| 1 | External context → public help center | Jira issue in project **DD** (mintlify-demo-ae) *or* Google Doc "Acme – Refund policy update (demo)" | [/acme/refunds](https://docs.marcodewey.com/acme/refunds) (public) | Jira: automatic on issue create. Doc: one click on **Run** |
| 2 | Non-code process change → internal KB | Google Doc "Acme Support – Escalation process v2 (demo)" *or* a Jira issue in DD | [/playbook/escalation-process](https://docs.marcodewey.com/playbook/escalation-process) + [/playbook/hours-and-on-call](https://docs.marcodewey.com/playbook/hours-and-on-call) (login required) | Doc: one click on **Run** (or ask the agent). Jira: automatic |

Each run takes about 1–2 minutes and opens a pull request in `mintlify-demo/docs` with a preview link. The PR description quotes the exact line of the source each change came from, which is the best thing to show a prospect.

Before the call (2 min):
1. Open these tabs: the source (Jira DD board or the Google Doc), the docs page that will change, Mintlify dashboard → **Workflows**, and GitHub PRs for `mintlify-demo/docs`.
2. For scenario 2, sign in to the docs once with the shared AE login (vault: "Mintlify demo docs login (AE shared)") so the internal playbook pages open.
3. Check the page shows the baseline text (table below). If it doesn't, the reset hasn't run yet: use the other scenario or ping Marco.

| Page | Baseline (before the demo) |
|---|---|
| /acme/refunds | "You can ask for a refund within **30 days**" |
| /playbook/escalation-process | Urgent **4 hours**, High **1 business day**, escalations go to the support lead |
| /playbook/hours-and-on-call | "There is no weekend on-call today." |

---

## Scenario 1: Jira ticket → public help center (Refunds)

**Talk track:** "Your support policy changed. The decision lives in a Jira ticket, not in code. Watch Mintlify read the ticket and update the customer-facing help center."

1. In Jira (mintlify-demo-ae.atlassian.net), open project **DD** and click **+ Create**.
2. Paste:
   - **Summary:** `Refund window is now 45 days; gift cards are non-refundable`
   - **Description:** `Approved by CX. Effective Dec 1, members can request a refund within 45 days of their order (was 30 days). Gift cards and gift subscriptions are non-refundable.`
3. Click **Create**. Say: "That's it, no one touches the docs."
4. Mintlify dashboard → **Workflows** → **Update docs from Jira issues** shows a new run (Jira is polled, so it can take 1–3 minutes to start).
5. When the run finishes, open its PR (title includes the DD key). Show the diff on `acme/refunds.mdx` (30 → 45 days, new gift-card warning) and the description quoting the ticket.
6. Open the **preview link**, or merge the PR (GitHub **Merge**, or **Publish** in the Mintlify editor), and refresh https://docs.marcodewey.com/acme/refunds about 1 minute later.
7. Bonus: after the merge, the **Translate Acme Help Center** workflow opens a second PR updating the Spanish and French pages.

**Same scenario from a Google Doc (no Jira needed):** open the Google Doc **Acme – Refund policy update (demo)**, add a bullet under "What changes for members": `Gift cards and gift subscriptions are non-refundable.` Then Dashboard → **Workflows** → **Update help center from Google Doc (demo)** → **Run**. Same PR and preview flow as above.

## Scenario 2: Google Doc process change → internal Support Playbook

**Talk track:** "This isn't a product change at all. The support team changed how they escalate, and they wrote it in a Google Doc. Mintlify reads the doc and updates the internal knowledge base, which only signed-in staff can see."

1. Show https://docs.marcodewey.com/playbook/escalation-process signed in (Urgent 4 hours, High 1 business day). Optionally open it in a private window to show it asks for a login.
2. Open the Google Doc **Acme Support – Escalation process v2 (demo)**. Click at the end of the last bullet under "What changes", press Enter, and type:
   `High-priority tickets: escalate after 4 hours (was 1 business day).`
3. Start the update, either way:
   - **One click (most reliable):** Dashboard → **Workflows** → **Update support playbook from Google Doc (demo)** → **Run**.
   - **Conversational:** in the dashboard agent chat, paste: `Update the internal Support Playbook (playbook/ pages) from this Google Doc and open a PR: <doc link>. Keep the pages internal.`
4. About 80 seconds later a PR opens, for example "Support playbook: escalation v2 and weekend on-call (from Google Doc)". Show the diff: Urgent 4h → 1h, High 1 business day → 4h, escalations go to the on-call agent first, and the new weekend on-call on the Hours page. The PR description quotes each doc line.
5. Merge it (or open the preview), then refresh the playbook page.

**Same scenario from Jira:** create a DD issue with Summary `Escalation process v2: urgent tickets escalate after 1 hour` and Description `Effective Dec 1. Urgent tickets escalate after 1 hour (was 4 hours). Escalations go to the on-call agent in #support-escalations first. New weekend on-call: Saturday and Sunday, 10am to 4pm Pacific.` The Jira workflow routes internal process changes to `playbook/`.

---

## If the agent is slow or something breaks

- **No run after 3 minutes (Jira):** Jira triggers are polled. Switch to the Google Doc version of the same scenario and click **Run**. It starts right away.
- **Run is going but slow:** keep talking through the source and the "Before" page, then show a previous PR from this flow: PR #90 in `mintlify-demo/docs` (Google Doc → playbook, tested Nov 19).
- **Merged but the page hasn't changed:** deploys take about 30–60 seconds. Hard-refresh, or show the PR's preview link.
- **Playbook page says to sign in:** that's the point (it's internal). Sign in with the shared AE login.
- Never click Close on someone else's open PR mid-demo. The nightly reset cleans up.

## Credits

Each workflow run uses about 250 Mintlify credits. Merging a help center change also starts a translation run (about 250 more). Run each scenario once per call.

## Reset (automatic, nightly 11 PM PT)

`mintlify-demo/demo-kit` → `.github/workflows/reset.yml` → `reset.sh`:
- Closes open Mintlify bot PRs and reverts merged ones in `docs`.
- Restores `acme/`, `es/acme/`, `fr/acme/`, `images/acme/`, **`playbook/`**, and the Acme Help Center nav tabs (which include the "Support playbook (internal)" group) from the `acme-baseline` tag.
- `verify.sh` checks the playbook pages exist and still require a login.

**Source docs** aren't reset by the Action (it has no Google or Jira credentials):
- Google Docs: delete the line you typed, or File → Version history and restore the version before your demo. Baseline text: `scenarios/escalation-doc-baseline.txt` and `scenarios/refund-doc-baseline.txt`.
- Jira: the issues you create stay in DD as history. They don't affect the next demo.
