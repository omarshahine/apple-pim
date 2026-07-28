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

That last row is the only thing that carries a claim from "this domain sent it" to "this
person sent it", and it requires an explicit operator assertion. Nothing infers it.

### Provenance

`Authentication-Results` is a header inside the message. A sender can write one. RFC 8601
only requires a receiving boundary to strip instances bearing *its own* identifier, so a
forged header using any other identifier arrives intact.

The channel therefore accepts authentication results only from an `authserv-id` the
operator configured for that account, and fails closed when none is configured. This is
per account, not per channel, because a single mailbox aggregates accounts sitting behind
different boundaries.

---

## Ingress: mail arriving (owned mailbox)

`dispatch` means the agent acts on it. `observe` means the agent may read and summarize but
not act or reply. `drop` means it never reaches the agent.

| # | Scenario | Domain | Address | Outcome |
| --- | --- | --- | --- | --- |
| I1 | Operator, authenticated, enrolled | `verified` | `verified` | `dispatch` |
| I2 | Operator's address, authentication failed | `asserted` | `asserted` | `drop` |
| I3 | Operator's address, no trusted `authserv-id` configured | `asserted` | `asserted` | `drop`, with a config warning |
| I4 | Enrolled non-operator (family, colleague) | `verified` | `verified` | `dispatch`, subject to sender policy |
| I5 | Authenticated stranger | `verified` | `asserted` | `observe` |
| I6 | Unauthenticated stranger | `asserted` | `asserted` | `drop` |
| I7 | Spoofed operator, forged `Authentication-Results` | `asserted` | `asserted` | `drop`, forged header never read |
| I8 | Spoofed operator, valid SPF for the attacker's own domain | `asserted` | `asserted` | `drop`, unaligned pass does not count |
| I9 | Reply inside a thread the agent started, from an addressed participant | inherits | inherits | `dispatch` (see E1) |
| I10 | Reply inside a thread the agent did not start | per I1-I6 | | as if new |
| I10a | Claimed thread membership from a non-participant | per I1-I6 | | thread claim ignored, treated as new |
| I11 | Bulk or marketing mail, authenticated | `verified` | `asserted` | `observe` |
| I12 | Forwarded mail | usually `asserted` | `asserted` | `observe` at best |
| I13 | Mail from the agent's own address | n/a | n/a | `drop`, loop guard |
| I14 | Mail in Junk | n/a | n/a | not polled |
| I15 | Mail with attachments | per above | | admission unchanged; attachments separately gated |

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

1. The claimed parent must be a `Message-ID` **the agent itself generated**. A thread root
   the agent never sent is not an agent-originated thread, whatever the headers say.
2. The sender must be an address **the agent actually addressed** in that thread. Forging
   `In-Reply-To` gains nothing unless you were already a participant, and a participant
   already had permission.

Both conditions come from state the agent wrote down when it sent the message. Neither is
read from the inbound message. That is the same discipline the rest of this document applies
to authentication: the evidence must come from a side the sender does not control.

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

**Rate and volume.** Default-deny bounds *who* the agent may contact, not *how much*. A
permitted recipient plus a loop the loop guard does not catch is still a way to send a
hundred messages. Volume limits are a separate control and are not covered here.

**Attachments.** Orthogonal to admission. Inbound attachments do not change a sender's
strength; outbound attachments are default-denied unless the operator opts specific paths in.

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
  assertion; nothing derives it.

## Configuration summary

| Control | Governs | Default |
| --- | --- | --- |
| Trusted `authserv-id`, per account | Which authentication results are believed | none, fails closed |
| Per-sender expected signing domains | Whether an address can reach `verified` | none, so no address is verified |
| Minimum identifier strength | The bar for admission | `asserted`, matching existing behavior |
| Egress recipient allowlist | Who the agent may originate mail to | empty, default-deny |
| Attachment allowed roots | Outbound attachments | empty, default-deny |

Every default is closed. An install that configures nothing reads nothing and sends nothing,
which is the correct resting state for a system whose failure mode is an agent acting on a
stranger's instructions.
