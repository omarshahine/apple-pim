---
title: "Mail Channel Scenarios"
description: "Every inbound and outbound mail scenario for an agent and its operator, and how the channel decides each one."
---

# Mail Channel Scenarios

Mail is the only common agent channel where the transport authenticates the *message*
rather than the *session*. Every other channel hands the agent a sender identity that some
gateway already proved. Mail hands it a string the sender typed, plus optional evidence
about that string, plus the possibility that the evidence itself was typed by the sender.

This document enumerates the scenarios that follow, and how the channel decides each one.
It is written to be readable without the implementation in front of you, because the point
of writing it down is to make the policy arguable before it is code.

## Two mailbox relationships

Before any of the scenarios below, one distinction decides which of them apply at all.

| | Owned | Delegated (OBO) |
| --- | --- | --- |
| Whose mailbox | the agent's own account | the operator's account |
| Who the agent is when it sends | itself | the operator |
| Who else reads the inbound mail | nobody | the operator, regardless of what the agent does |
| The question egress answers | may the agent contact this person? | is the agent authorized to act as the operator toward this person? |

**The three questions, the ingress section, and the egress section describe the owned
case**, which is what this channel implements. The delegated case is genuinely different,
not a relaxation of the same rules, and is covered in its own section,
[Delegated mailboxes](#delegated-mailboxes-obo). Cross-cutting concerns apply to both.

In this deployment the split is concrete: the Apple Mail account is owned, and a separate
agent handles the operator's Fastmail account under delegation. They are different accounts
with different rules, not one policy at two strictness levels.

Getting these backwards is the expensive mistake. Applying owned-mailbox default-deny to a
delegated mailbox produces an assistant that cannot do its job, and applying delegated
looseness to an owned mailbox produces an agent any stranger can drive.

## The three questions

Every decision in this document reduces to three independent questions. Conflating any two
of them produces a bug, and most mail-agent designs conflate at least one.

| Question | Answered by | Failure if conflated |
| --- | --- | --- |
| **Who does this message claim to be from?** | The `From` header | Trusting a string anyone can type |
| **Did our own trust boundary prove that claim?** | DKIM/SPF/DMARC results stamped by a pinned `authserv-id` | Reading evidence the sender wrote |
| **Is that identity enrolled with us?** | Operator configuration | Treating an authenticated stranger as a known correspondent, or as a spoofer |

The channel keeps these separate. Authentication is evaluated for **every** sender,
including strangers, and enrollment gates only what the identity is permitted to do.

### Strength, per identifier

One message yields several identifiers, and they are not equally trustworthy. This matters
because DMARC alignment authenticates a **domain**, never a mailbox.

| Identifier | Reaches `verified` when |
| --- | --- |
| Display name | Never. It is sender-chosen. |
| Sender domain | An aligned DKIM signature, or an aligned SPF pass, from a trusted boundary |
| Full address | The above, **and** the signing domain is one the operator listed for that specific sender |

Reading the address off the display string is itself a step that can be got wrong, which is
why the CLI does not make callers take it. `messages`, `search`, and `get` return
`senderAddress` and `senderName` as separate fields (the SQLite engine reads them from two
separate columns; nothing is parsed). The joined `sender` string is for display only: a
display name may contain an `@`, and a real phishing message used `service@paypal.com` as
the display name in front of an unrelated address. Splitting that string on the first token
reports the forged half and reads as PayPal; RFC 5322 parsers give up and report nothing.
Neither failure is catchable by authentication — SPF, DKIM and DMARC all pass on such a
message, because it genuinely was sent through the From domain's infrastructure and DMARC
does not cover the display name.

That last row is the only thing that carries a claim from "this domain sent it" to "this
person sent it", and it requires an explicit operator assertion. Nothing infers it. In
particular an aligned SPF pass alone never gets there: SPF authenticates an envelope
*domain*, so on any shared domain every user of it passes aligned SPF and would authenticate
as every other.

The three levels have to stay honest about the bottom of the scale, which is the part that
is easy to get wrong:

| Level | Means | An identifier gets it when |
| --- | --- | --- |
| `verified` | our boundary proved this exact mailbox | an expected signer signed it |
| `asserted` | our boundary proved the domain, and nothing narrower | the domain authenticated but no operator assertion names the mailbox |
| `unverified` | presented by a party nobody authenticated; stable, attacker-chosen, unproven | authentication produced nothing |
| `mutable` | a user-changeable alias that identifies nobody even when honestly set | always, for a display name |

A `From` header on a message that failed authentication belongs in `unverified`. Scoring it
`asserted` gives the address identifier a floor, which silently turns the lowest configurable
minimum into no minimum at all, and every scenario below that says `drop` stops dropping.
That was a real defect here, not a hypothetical.

The bottom two levels are both untrustworthy and are kept apart because they are
untrustworthy for *different reasons*. An alias is weak because two people can hold the same
one. An unauthenticated address is weak because nothing bound it to its sender, though it is
perfectly precise. This channel emits exactly one of each: the display name is always
`mutable`, and no address is ever `mutable`. Collapsing them, which an earlier version of
this channel did, yields the right admission and a diagnostic that calls a precise address a
nickname.

### Provenance

`Authentication-Results` is a header inside the message. A sender can write one. RFC 8601
only requires a receiving boundary to strip instances bearing *its own* identifier, so a
forged header using any other identifier arrives intact.

The channel therefore accepts authentication results only from an `authserv-id` the
operator configured for that account, and fails closed when none is configured. This is
per account, not per channel, because a single mailbox aggregates accounts sitting behind
different boundaries.

Failing closed has to be *legible*, though, or it is indistinguishable from having checked.
`auth_check` returns an `evaluated` flag beside the verdict: `false` means the DKIM/SPF
checks never ran — no headers, no trusted `authserv-id`, no sender address — and `checks` is
empty for that reason rather than because the evidence was inconclusive. A caller that reads
`unknown` as "checked, could not tell" and skips `evaluated` is acting on a check that did
not happen. The warnings alongside it name what is missing, including the `authserv-id`
values observed on the message, so configuring the boundary is a copy step.

A missing `trusted-senders.json` does not stop the check. Nobody is enrolled, so nothing can
reach `verified`, but that is the same state as every sender being unenrolled — which is
already handled, because enrollment and authentication answer different questions. A file
that exists and will not parse is the opposite case: the operator wrote a policy that is not
being applied, and the command exits non-zero rather than evaluating against an empty one.

---

## Ingress: mail arriving (owned mailbox)

`dispatch` means the agent acts on it. `observe` means the agent may read and summarize but
not act or reply. `drop` means it never reaches the agent.

| # | Scenario | Domain | Address | Outcome |
| --- | --- | --- | --- | --- |
| I1 | Operator, authenticated, enrolled | `verified` | `verified` | `dispatch` |
| I2 | Operator's address, authentication failed | `unverified` | `unverified` | `drop` |
| I3 | Operator's address, no trusted `authserv-id` configured | `unverified` | `unverified` | `drop`, with a config warning |
| I4 | Enrolled non-operator (family, colleague) | `verified` | `verified` | `dispatch`, subject to sender policy |
| I4a | Allowlisted, domain authenticated, **not** enrolled | `verified` | `asserted` | `dispatch` at the default minimum, `observe` under `verified` |
| I5 | Authenticated stranger | `verified` | `asserted` | `observe` |
| I6 | Unauthenticated stranger | `unverified` | `unverified` | `drop` |
| I7 | Spoofed operator, forged `Authentication-Results` | `unverified` | `unverified` | `drop`, forged header never read |
| I8 | Spoofed operator, valid SPF for the attacker's own domain | `unverified` | `unverified` | `drop`, unaligned pass does not count |
| I9 | Reply inside a thread the agent started, from an addressed participant | inherits | inherits | `dispatch`, or `observe` if the address is under the minimum (see E1) |
| I10 | Reply inside a thread the agent did not start | per I1-I6 | | as if new |
| I10a | Claimed thread membership from a non-participant | per I1-I6 | | thread claim ignored, treated as new |
| I11 | Bulk or marketing mail, authenticated | `verified` | `asserted` | `observe` |
| I12 | Forwarded mail, alignment broken in transit | usually `unverified` | `unverified` | `drop` unless the forwarding address is enrolled |
| I13 | Mail from the agent's own address | n/a | n/a | `drop`, loop guard |
| I14 | Mail in Junk | n/a | n/a | not polled |
| I15 | Mail with attachments | per above | | admission unchanged; attachments separately gated |

Every row is executed against the real policy in `openclaw/src/mail-channel/scenarios.test.ts`,
at both configured minimums, so this table and the code cannot drift apart again.

### The scenarios worth explaining

**I2, and why the operator is not special.** An operator's address that fails
authentication is dropped, not escalated. The whole point of the model is that the `From`
header carries no weight on its own, and making an exception for the most valuable identity
in the system would invert that. If the operator's own mail stops arriving, the correct
response is to fix the authentication path, not to add a bypass.

**I3, fail-closed and why it is loud.** With no configured `authserv-id`, the channel
cannot distinguish a genuine result from a forged one, so it trusts neither. This means a
misconfigured install processes nothing, which is the safe direction but an opaque failure.
The channel therefore reports the `authserv-id` values it actually observed on the message,
so configuring it is a copy step rather than an investigation.

**I5 is the scenario that justifies the whole design.** An authenticated stranger is not a
threat and not a correspondent. The transport genuinely proved which domain sent the
message; nothing proved this human should be able to direct an agent. Reading it is useful.
Acting on it is not acceptable. A binary allow/deny model cannot express this, which is why
the older "sender is in my address book" rule could not either: it never fired for
strangers at all, so an authenticated stranger and a spoofed one were equally invisible.

**I4a is the configuration everyone actually has.** Two lists must agree for an address to
reach `verified`: `allowFrom` says who may drive the agent, and `trusted-senders.json` says
what proves they are who they claim. Adding someone to the first and forgetting the second
is the normal state of a half-configured install, and it is not an attack.

So a grant that fails to apply must leave the sender exactly where an ungranted one lands,
never below it. An allowlisted sender whose mailbox is not enrolled is the I5 case, an
authenticated stranger, and is treated as one. The earlier design dropped them instead,
which meant adding an address to `allowFrom` *reduced* what the channel did with their mail:
a silent inversion landing precisely on the addresses the operator cared enough to
configure. The same reasoning applies to thread permission (I9).

Under `minIdentifierAuthentication: "verified"` this is still a real restriction. The
message is readable and not actionable, which is the honest answer, and the channel reports
every `allowFrom` entry with no enrollment behind it when the account starts, so the gap is
visible rather than inferred from an agent that reads mail and never answers.

**I7 and I8 are the two live attacks.** Both were real defects in this codebase before the
current design. I7 is a forged `Authentication-Results` header that a naive parser reads as
genuine. I8 is an SPF pass for the attacker's own envelope domain being counted as
authentication of a `From` address it has nothing to do with. Neither requires anything
exotic; both are trivially reachable by any sender.

**I12, forwarding, is a real and unavoidable loss.** Forwarding usually breaks SPF and often
breaks DKIM alignment. Forwarded mail from a person the operator trusts will generally not
reach `verified`, and will be treated as a stranger. This is correct: the forwarder, not the
original author, is who the transport can speak for. Operators who need forwarded mail
handled should enroll the forwarding address.

**I13, loop prevention, is not optional.** An agent that can send mail and read mail can
answer itself. The channel drops mail from any address it sends as, before policy is
consulted.

---

## Egress: mail leaving (owned mailbox)

Egress is **default-deny**. The agent may not originate mail to an address unless the
operator has permitted it. Inbound authentication strength grants nothing outbound: proving
who sent you a message says nothing about who you may contact.

| # | Scenario | Permitted | Basis |
| --- | --- | --- | --- |
| E1 | Reply within a thread the agent originated | yes | Thread rule |
| E2 | Reply within a thread the agent did not originate | no | Not covered by the thread rule |
| E3 | New mail to the operator | yes | Operator is always a permitted recipient |
| E4 | New mail to an enrolled correspondent | only if allowlisted for egress | Enrollment is inbound; egress is separate |
| E5 | New mail to an arbitrary address | no | Default-deny |
| E6 | Mail the operator explicitly asked the agent to send | yes, for that instruction | Operator instruction is the authority |
| E7 | Forwarding an inbound message onward | no, unless the recipient is permitted | Forwarding is originating |
| E8 | Reply-all where some recipients are unknown | reply narrowed to permitted recipients | Unknown recipients are not silently included |
| E9 | Mail with attachments | separately gated | Attachment policy is default-deny with explicit allowed roots |
| E10 | Mail to the agent's own address | no | Loop guard |

### Enforcing egress on `send`

The reply path is contained by the admission store: an `observe`-only sender cannot be
answered, because the channel records that decision and the `apple_pim_mail` tool honors it.
`send` originates a fresh message to arbitrary recipients with no message id, so that store
has nothing to key on. Left ungoverned, `send` would be a hole straight through default-deny:
an agent that read a stranger's mail could email that stranger, or anyone, without ever
touching the reply gate.

A `before_tool_call` hook closes it by running the send's recipients through the same
`decideEgress` the reply path uses, so the two cannot disagree about who the agent may
originate mail to. A fresh send is neither a thread the agent started nor proof the operator
asked for this exact message, so only two grants apply silently: the operator, and the
explicit egress allowlist. Everything else resolves to one of:

- **operator or allowlisted recipient** — the send proceeds.
- **any recipient off the allowlist** — the operator is asked to approve, over their regular
  channel (the same approval surface as `/approve`), naming the recipients and subject. The
  send fails closed on deny or timeout. Approval is `allow-once`: adding a correspondent
  permanently is an `egressAllowlist` edit the operator makes deliberately, not a one-tap
  side effect.
- **the agent's own address** — hard-denied without an approval prompt. Emailing itself is a
  loop (E10, I13), never a decision to delegate.

The hook runs inside the OpenClaw runtime, where the channel config and the approval surfaces
live. A bare MCP deployment of the tool has neither, so there the tool's own caller is the
trust boundary, exactly as it is for the read/reply gate when the shared store is absent.

### The thread rule

A reply is permitted when both hold:

```
isThread && threadOriginatedFromAgent
```

Nothing more. No inactivity window, no turn cap, no explicit close. If the agent started
the conversation, it may continue it; if it did not, replying is originating and falls under
default-deny.

**Thread membership cannot be taken from the message.** `References` and `In-Reply-To` are
sender-controlled headers, exactly like `From`. A sender who learns a `Message-ID` from an
agent-originated thread, by being forwarded a copy or by any other leak, can set
`In-Reply-To` to it and claim membership. Under a naive reading of the rule that claim would
earn reply permission, which would make the thread rule a hole in default-deny rather than a
narrow exception to it.

So the claim is checked against the agent's own record, on both ends:

1. The claimed parent must be a `Message-ID` **the agent recorded** for that thread.
2. The sender must be an address **the agent actually addressed** in it. Forging
   `In-Reply-To` gains nothing unless you were already a participant, and a participant
   already had permission.

Both come from state the agent wrote down when it sent. Neither is read from the inbound
message.

### Two kinds of anchor, and why the weaker one is still sound

Condition 1 would ideally match only Message-IDs the agent *generated*: unguessable, and
absent from inbound mail until the agent sends. `mail-cli smtp-send` mints its own and
returns it, so that anchor is available on that path. Mail.app does not — it assigns a
Message-ID internally and reports nothing back — so a reply sent through `mail-cli reply`
can only record the **inbound** Message-ID it was replying to.

Inbound anchors are not secret. The original sender knows one, and so does anyone Cc'd or
forwarded a copy. Recording them anyway is safe, but the reason is worth stating plainly
rather than glossing:

> An anchor selects a thread. It does not grant entry to one.

Knowing an anchor buys an attacker nothing on its own, because condition 2 still requires
them to be an address the agent addressed, and admission independently requires that address
to meet `minIdentifierAuthentication` — thread permission waives the allowlist, never
authentication (I9). To use a stolen anchor you must authenticate as a participant, at which
point you are that participant.

The two are kept as separate fields and the decision reports which one matched, so an audit
can tell a thread proven by the agent's own Message-ID from one resolved through an anchor
the sender could also have known. Moving a deployment to `smtp-send` upgrades its threads to
the strong anchor with no policy change.

A consequence worth knowing: a correspondent whose client sets `In-Reply-To` but writes no
`References` chain names only the agent's own reply, which the Mail.app path never learned.
That reply is denied. Full `References` chains are near-universal, but this is a real
false-negative and the reason the strong anchor is worth having.

Two further properties the rule must preserve:

- **It is scoped to the thread, not the sender.** Replying inside a thread must never widen
  into standing permission to contact that address. When the thread ends, so does the
  permission.
- **Two messages from the same person in different threads are two different decisions.**
  Permission does not generalize across threads any more than it generalizes across
  addresses.

**E2 deserves its own note**, because it is the case people expect to work. Someone
authenticated writes to the agent unprompted; the agent may read it (I5) but not answer it.
That asymmetry is deliberate. Answering is how an unknown party discovers the agent exists,
confirms a human is behind it, and starts a conversation on their terms. The operator can
always permit the address explicitly, which is the point: it should be a decision.

---

## Delegated mailboxes (OBO)

A delegated mailbox is the operator's, and the agent acts as them. Two consequences run
through everything below.

**Admission stops being a shield.** On an owned mailbox, dropping a message means nobody
sees it. On a delegated mailbox the operator receives the mail regardless; admission only
decides whether the *agent* processes it. So the useful question is never "should this
message exist" but "may the agent act on it", and the honest default for unauthenticated
mail is to read it and act on nothing it says.

**Egress gets riskier, not safer.** Sending as the operator borrows their reputation.
A recipient who sees the operator's address extends the trust they have in the operator, not
the trust they have in an assistant. A successful injection on a delegated mailbox can
therefore do more damage than the same injection on an owned one, even though the mailbox
feels more trusted. Delegated egress deserves *more* scrutiny than owned egress, of a
different kind: not "may we contact them" but "would the operator have sent this".

| # | Scenario | Owned answer | Delegated answer |
| --- | --- | --- | --- |
| D1 | Reply in a thread the **operator** originated | not applicable | permitted; this is ordinary delegated work |
| D2 | Reply in a thread a third party originated, operator already a participant | as if new (I10) | permitted; the operator is already in the conversation |
| D3 | New mail as the operator to a known correspondent | default-deny (E5) | permitted with approval |
| D4 | New mail as the operator to a never-seen address | default-deny (E5) | approval, and the highest-scrutiny case here |
| D5 | Destructive mailbox operations (bulk delete, bulk move) | not offered | explicit operator instruction only |
| D6 | Unauthenticated inbound arrives | `drop` (I6) | read and summarize; act on nothing it instructs |
| D7 | Inbound content instructs the agent to send mail | never reaches the agent | the send is still gated by D3/D4; content cannot self-authorize |

### What changes in the rules

**The thread test inverts.** The owned rule asks `threadOriginatedFromAgent`, because on its
own account an agent replying to a stranger is originating contact. On a delegated mailbox
the equivalent test is whether the **principal** is already in the thread. The agent
replying inside a conversation the operator is having is continuing their work, not starting
something new.

The forgery protection carries over unchanged, and matters more: membership must still be
established from recorded state rather than from `References` and `In-Reply-To`, because
here a forged claim buys the ability to send as the operator.

**The operator changes role.** In the owned model the operator is a permitted *recipient*.
In the delegated model they are the *sender identity being assumed*, which the owned model
has no way to express. Egress policy for a delegated mailbox needs a "sending as" axis that
owned egress does not have, and conflating the two is how an agent ends up treating the
operator's address as merely allowlisted.

**Recipient allowlists mostly stop making sense.** Operators mail whoever they like, so an
allowlist would be permanently out of date. The control that carries the weight is approval
on origination (D3, D4), not enumeration of recipients.

### Not yet implemented

The policy code in this plugin implements the owned model only. `decideEgress` reasons about
recipient permission and has no concept of sending *as* another identity, so it must not be
pointed at a delegated mailbox as-is. In this deployment the delegated case is handled by a
separate agent against a separate account, which is the right seam; a delegated channel would
need its own policy module rather than a flag on this one.

## Cross-cutting concerns

**Approvals.** Where a scenario is denied by policy but reasonable to allow case by case,
the channel should raise an approval rather than fail silently. A denial the operator never
sees is indistinguishable from a bug.

**Audit.** Every admission decision records the reason code and the strengths that produced
it. "Why did the agent not answer that?" must be answerable after the fact, and the answer
must not require re-reading the mailbox.

**Rate and volume.** Default-deny bounds *who* may drive the agent, not *how much*. One
permitted correspondent, a mailing list that starts looping, or a mail rule gone wrong all
produce unbounded agent runs from an entirely authorized sender, and every control above
correctly waves each one through.

A circuit breaker counts runs per hour and per day (`maxAgentRunsPerHour`,
`maxAgentRunsPerDay`). It counts runs rather than judging senders: a per-sender breaker
would let ten senders cost ten times as much, which is the failure it exists to prevent.
When it trips the channel holds its cursor instead of discarding the backlog, so a burst is
deferred and never lost. That costs a re-authentication per held message each cycle, which
is the right trade: authentication is cheap, and losing the operator's mail to a flood of
newsletters is not recoverable.

**Attachments.** Orthogonal to admission. Inbound attachments do not change a sender's
strength; outbound attachments are default-denied unless the operator opts specific paths in.

Inbound attachments are never fetched automatically. The envelope reports that they exist
and the agent saves one only if it decides to, through the same gate as a body.

**What the agent is given.** The envelope, never the message: sender, subject, date,
attachment count, and the message id. Sender and subject are usually enough to tell a
newsletter from an instruction, and on a real mailbox most admitted mail is `observe`, so
fetching every body meant a model call per newsletter whose reply was then discarded.

This moves the security boundary onto the tool. A dropped message still has an id, and a
general-purpose mail tool will read any id it is given, so an agent that learns one could
fetch the body the channel just refused to deliver. The channel therefore quarantines the
ids it drops, and `apple_pim_mail` refuses to read or save attachments from them. Lazy
fetch without that gate is a bypass, not an optimization.

Blocking direct reads is not sufficient on its own. `search --field content` reads every
candidate body, so an unfiltered hit is a content oracle: the agent probes for a phrase and
learns from the result whether a quarantined message contains it, without ever opening one.
Listings leak the envelope the same way. Quarantined messages are therefore withheld from
listing and search results as well, and the response says how many rows were withheld, since
a quietly short listing is indistinguishable from an empty mailbox.

**Volume ceiling.** The channel reads the *oldest* unprocessed mail each cycle, paging
forward from its cursor, so a full page simply means the backlog is still draining.

This was originally newest-first, and that could not be made correct. The page grows
backwards from now, so once more than one page of mail sat between the cursor and the
present, older messages were unreachable: advancing the cursor skipped them, holding it
redelivered the newest page forever and still never reached them. Worse, it was reachable on
purpose. Anyone able to flood the mailbox could push a real message permanently out of view,
and unauthenticated mail consumed page capacity before it was ever classified. Paging forward
from the cursor removes the whole class: a flood is newer than the backlog, so it sorts
behind it and waits its turn.

**Polling, not push.** The channel reads the local mail store on an interval rather than
depending on a mail-client rule to wake it. That removes a GUI dependency, and it means the
filter lives in the channel where policy belongs, instead of upstream where it would decide
what the agent is even allowed to see.

## Deliberately not supported

- **Trusting a `From` header on its own.** There is no configuration that enables it.
- **Escalating the operator past authentication.** See I2.
- **Inferring egress permission from inbound trust.** They are separate grants.
- **Standing permission earned by replying.** See the thread rule.
- **Thread membership asserted by the sender.** `References` and `In-Reply-To` are claims,
  not credentials. Membership is checked against what the agent recorded sending.
- **Authenticating a mailbox from a domain proof.** Requires an explicit per-sender
  assertion; nothing derives it. There is deliberately no way to reach `verified` on an
  aligned SPF pass alone, because on a shared domain every user of it passes aligned SPF and
  would authenticate as every other.
- **A grant that lowers admission.** Being on `allowFrom`, or inside a thread the agent
  started, can only ever admit a sender further than they would get without it (I4a, I9).

## Configuration summary

| Control | Governs | Default |
| --- | --- | --- |
| Trusted `authserv-id`, per account | Which authentication results are believed | none, fails closed |
| Per-sender expected signing domains | Whether an address can reach `verified` | none, so no address is verified |
| Minimum identifier strength | The bar for admission | `asserted`: the sender's domain must have authenticated |
| Egress recipient allowlist | Who the agent may originate mail to | empty, default-deny |
| Attachment allowed roots | Outbound attachments | empty, default-deny |

The two minimums are different postures, not strictness dials on the same one:

- **`asserted`** requires the transport to have proved the sender's *domain*. It admits an
  allowlisted sender whose mailbox is not separately enrolled, and rejects every message
  that authenticated nothing. This is the useful default.
- **`verified`** additionally requires an operator assertion binding that mailbox to its
  signers. It is the right posture once enrollment is complete, and until then it leaves
  allowlisted senders readable but not actioned (I4a).

`asserted` is a real bar only because an unauthenticated `From` address scores `unverified`.
If it scored `asserted`, this row would be decorative and I2, I7, and I8 would all dispatch.
The channel reports any `allowFrom` entry with no enrollment behind it at startup, so the
gap between the two files is visible rather than inferred.

Every default is closed. An install that configures nothing reads nothing and sends nothing,
which is the correct resting state for a system whose failure mode is an agent acting on a
stranger's instructions.
