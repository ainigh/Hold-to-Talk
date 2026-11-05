# What you like is a function of kind

The rule behind every request about Holdnote's window, written down so it can be applied before the request comes.

## The function

> **What happens when you act on a thing depends only on what kind of thing it is.**
>
> `experience(thing) = f(kind(thing))`

Two things of the same kind must do the same thing when you click, select, hover, or look at them: the same buttons in the same places, the same panels beside them, the same text layout, the same shortcuts. If you can tell two things of one kind apart by what happens when you act on them, that is a bug, whatever the reason the difference crept in.

This is why a request is predictable: once a text has a Copy button, every text needs one; once a text has a conversation beside it, every text does; once a panel has sections, every section can open beside the text. The person is not choosing feature by feature. They are applying `f` and noticing where the app does not.

## The corollaries

- **A feature belongs to a kind, never to an instance.** "Does Goals really need Words?" is the wrong question. Goals is a text; texts have Words. If Words is wrong for texts, take it from all of them.
- **Position is part of the experience.** Copy at the top of one text and at the bottom of another is two experiences. Same kind, same place.
- **Layout is part of the experience.** One text centred with margins and another full width is two experiences.
- **Opening is part of the experience.** If choosing a row opens its thing in the next column, every row of that kind opens in the next column; if a panel's section can be shown on its own beside the text, every section can.
- **Absence is allowed, difference is not.** A text with no audio has no Play button: the data is absent, so the action is absent. That is not a difference of kind. A text with audio and no Play button would be.
- **Fewer kinds is the goal, not more features.** Every time two things turn out to be the same kind, the app gets simpler to predict. Goals, an item and ALL are all texts; three sets of chrome became one.

## How this relates to VFD

`VFD.md` is the mechanics; this is what it is for. In VFD's terms, a kind is a group of axes with one contract, and `f` is the rule that every instance of the kind is a configuration of the same axes. VFD's "asymmetry between similar things" smell is exactly a violation of `f`. The spec is not the point; predictability is. The spec is how the predictability is kept honest.

## The kinds in Holdnote's window

| Kind | Instances | What every instance gets |
|---|---|---|
| **Text** | an item of the stream, ALL (the whole stream), Goals | A header line with what it is and its measure; the text full width, editable when it is yours; a footer with Copy first, then the actions the data allows (Append, Re-transcribe, Delete, Play when there is audio); a side chooser for what sits beside it: the reader's take, its questions for you, what was noticed, the conversation, its words, or nothing; select a passage and right-click to ask about it |
| **Side panel** | the reader's take, questions for you, what was noticed, the conversation, the words | Beside the text when there is room, under it when not; one chooser; each section of a composite panel can be shown alone |
| **List row** | a stream item, Goals, ALL, a note file, a settings page, a status page | Choosing it opens its thing in the columns to the right; a meta on the right; a mark when the reader has something to say |
| **Running thing** | a recording, a transcription, the reader reading, the index | Shows at the top of the window with its Stop or Pause, and on Status → Now with the same button |
| **Standing question** | the questions about your goals, pinned questions from the conversation | Kept answered as the stream grows; pin and unpin from either place |
| **Switch** | the hotkey, voice detection | At the top left of the window, with the running things |

A new instance of a kind inherits the row. A new feature goes into the row, and so into every instance.

## The test

Before adding anything, ask: what kind is this, and what does every other instance of that kind do? Add to the kind. If the thing fits no kind, it is either a new kind (rare, and worth naming here) or a sign that an existing kind is drawn wrong.
