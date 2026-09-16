# Data residency — the question to put to counsel

Status: **open, blocking.** Written 2026-09-14. Blocks step 1 of
`kubernetes-platform-design.md` §17, because region is the one property that is expensive to
change after the fact.

This document exists to be sent to a Vietnamese data-protection lawyer. It states the facts,
asks four questions, and lists what each possible answer would cost us. It is deliberately short.

---

## Facts

**The company.** Quy Nhon Semiconductor (QNSC), a Vietnamese company. Our AWS account
(`608983206583`) is a member account in the AWS Organisation of TrueIDC, a Thai company, which
pays the bill under consolidated billing. We control the account; TrueIDC is the payer.

**Where the data is today.** All infrastructure runs in AWS **ap-southeast-1 (Singapore)**.
Object storage is Cloudflare R2. **AWS has no region in Vietnam.** The nearest alternatives are
Singapore, Jakarta, Hong Kong and Bangkok — all outside Vietnam.

**The products, and the personal data each holds.**

| product | users | personal data held |
| --- | --- | --- |
| rova | business customers (B2B) | employee names, work email, authentication identity |
| opshub | our own staff, internal only | staff identity |
| qnsc-kb | business customers (B2B) | documents customers upload, which may contain anything |
| **LMS (VLSI Academy)** | **individual students in Vietnam** | **name, email, enrolment, progress, completion certificates, payment reference** |
| solodesk | to be determined | to be determined |

**The LMS is the reason this question is being asked now.** It is the only product whose users
are individual Vietnamese citizens at scale rather than business contacts, and it is the newest,
so it is the one that can still be built differently at no cost.

---

## The four questions

1. **Does Decree 53/2022/ND-CP data-localisation apply to any of these products?** If so, which,
   and does it require storing data in Vietnam, or only establishing a local presence and
   retaining the ability to produce data on request?

2. **What must we file for the cross-border transfer under Decree 13/2023/ND-CP (PDPD)?**
   Specifically: is a Transfer Impact Assessment dossier required for each product, what is the
   filing deadline relative to first processing, and does the Singapore location change the
   answer versus a Vietnamese location?

3. **Does the TrueIDC arrangement create a separate issue?** A Thai company is the AWS payer and
   the organisation management account. It has no access to our data, but it is the account's
   billing owner and could technically exercise organisational control. Does this constitute a
   transfer or a processor relationship that must be disclosed?

4. **What is the practical enforcement posture?** We are a small company and would like to know
   whether the realistic answer is "file the dossier and proceed" or "this genuinely requires
   domestic hosting".

---

## What each answer costs us

We are asking now because the answers have very different prices, and only one of them is cheap
after we have built.

**Answer A — Singapore is fine, with a filing.**
No architecture change. We complete the dossier and proceed. This is the outcome we are planning
for.

**Answer B — Vietnamese personal data must stay in Vietnam, but only for the LMS.**
The LMS student database and its uploaded files move to a Vietnamese provider (Viettel IDC, VNPT,
FPT or CMC) while the rest of the estate stays on AWS. This is workable but it means the LMS is
not on the shared platform — a second deployment target, a second set of operational
procedures, and a network path between them. **Expensive, and much more expensive after the LMS
is built than before.**

**Answer C — all Vietnamese personal data must stay in Vietnam.**
rova and qnsc-kb move too. AWS has no Vietnam region, so this is not a region change — it is a
different cloud provider, and most of the design in `kubernetes-platform-design.md` would have to
be re-evaluated against what that provider offers. **This is the answer that must not arrive
after we have migrated.**

---

## What we need back, and when

A written determination of A, B or C, plus the list of filings required either way.

**We need it before we create the Kubernetes clusters** — the first step of a platform migration
that is otherwise ready to start. If the answer takes time, tell us which answer to plan for in
the meantime, because building for A and discovering C is the one sequence we cannot recover from
cheaply.

---

## Contacts

Prepared by: <nghiavt@qnsc.vn>
Related documents: `infra/docs/kubernetes-platform-design.md` §17, `VLSI-ACADEMY-LMS-PLAN.md`
