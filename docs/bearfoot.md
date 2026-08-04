# bearfoot

*An easter egg that had to earn its keep, so it became a check.*
Run it: `python3 scripts/bearbrowser-verify-bearfoot.py`

## The track

A bear is **plantigrade** — it walks on the whole sole, heel through toe, the way we do. Nearly
every other four-legged animal walks on its toes. The consequence is that a bear's hind print is
startlingly like a **barefoot human print**: a broad sole, five toes, a heel.

That single anatomical fact is why, across the whole northern hemisphere and quite independently,
peoples who share ground with bears name the bear **kin** — *the one who walks like a man*. Skinned,
a bear looks disquietingly human, and the tracks it leaves say the same thing. This is not one
people's story; it is what anyone reading the ground would conclude.

## The property

> **A print that distinguishes you is a print that betrays you.**

Anti-fingerprinting does not hide your track. It makes **every track the same track**, so that no
single print identifies anyone. You are not concealed — you are *indistinguishable*, which is the
stronger thing. You walk as one of many.

From which a real invariant follows, and the reason this is a script and not a comment:

> **THE BEARFOOT PROPERTY** — every BearBrowser profile that flattens its print must flatten it
> **the same way**. If `human-secure` and `agent-runtime` disagree on a print-surface pref, that
> disagreement is *itself* a distinguishing bit: an observer still cannot tell you from other
> users, but *can* tell which BearBrowser you run. **The herd only protects you if the herd is
> uniform.**

`scripts/bearbrowser-verify-bearfoot.py` refuses both failure modes — a profile that omits a
print-surface pref, and two profiles that set one differently. Silence is not agreement.

## Barefoot

The pun is load-bearing. **At the threshold you uncover your feet.**

*"Put off thy shoes from off thy feet, for the place whereon thou standest is holy ground"*
(Ex 3:5) — said to Moses at the bush, **before he is sent**, and long before Nebo where he will
look across and not enter.

And the Talmud gives the other half: *"the feet of a person are responsible for him; to the place
where he is in demand, there they lead him"* (*Sukkah* 53a). The Aramaic word is **`arevin`** —
**guarantors**. Your feet stand surety for you; they will deliver you. Solomon sent his scribes
away from death and the sending *was* the delivery.

But a guarantor must be **independent of the subject**, and your feet are not — they are yours,
their authority derives wholly from you. So:

> **Your feet are your guarantors, and that is exactly why they cannot be your witness.**
> They carry you to the threshold. They cannot vouch for you at it.

Which is the same law this codebase enforces elsewhere: a browser's own claim about itself is not
evidence about it. The print has to be checked by something that isn't the browser.

## On the bear medicine, said carefully

Bear is **sacred medicine** in many indigenous traditions of this continent — a healer's medicine,
associated with strength, introspection, and the dreaming that goes with the winter den. Those are
living traditions, not mythology, and much of what surrounds them is **ceremonial and closed**.
Nothing here reproduces or claims any of it.

For the Lenape specifically, on whose homelands much of this estate's founding geography sits: the
**Mesingw** (Misingw, *Living Solid Face*, the Mask Spirit) is the guardian of the game animals —
deer, bear and the rest — a sacred medicine being, and a focus of living Big House ceremony. He is
described here only as the Delaware Tribe and public language resources describe him, and he is a
**guardian**, not a returning god.

**An honest gap.** This document was asked to name a Lenape "returning god" figure associated with
the bear. **It could not be verified and is deliberately not supplied.** The nearest attested things
are Mesingw (a guardian, not a returner) and the prophet **Neolin** (1761), whose Master-of-Life
vision drove a renewal movement — *restoration of ways*, not the return of a deity. Inventing or
mis-naming another people's sacred figure would be a real harm, so the blank is left as a blank.
If the source turns up, it can be added with proper attribution.

---

*Sources are provenance for engineering doctrine, not claims on anyone's tradition. The natural
history (plantigrade gait, human-like tracks, the resulting kinship motif) is public and general.
Where this document and the checker disagree, the checker ships.*

*Further reading, as cited rather than paraphrased:*
- [Mesingw, the Lenape Mask Spirit](http://www.native-languages.org/mesingw.htm) · [Delaware Tribe of Indians — Culture FAQs](https://delawaretribe.org/cultural-education/culture-and-language/culture-faqs-3/)
- [Neolin, the Delaware Prophet](https://en.wikipedia.org/wiki/Neolin)
- [Sukkah 53a](https://www.sefaria.org/Sukkah.53a)
