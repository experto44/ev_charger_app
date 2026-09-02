# Spoken guidance — the recordings

Drive mode speaks by playing short recordings back to back, not by synthesising
speech. A Tesla's browser has no speech voices installed at all, and it
certainly has no Georgian one, which is why the car drove in silence.

An instruction is at most two clips: a distance and a maneuver.

> `in200.mp3` + `right.mp3` → "ორას მეტრში. მოუხვიე მარჯვნივ."

Street names are never spoken. They are on the banner, and no set of recordings
could cover them.

## Where the files go

```
tesla/assets/voice/ka/f/<id>.mp3    Georgian, woman
tesla/assets/voice/ka/m/<id>.mp3    Georgian, man
tesla/assets/voice/en/f/<id>.mp3    English, woman
tesla/assets/voice/en/m/<id>.mp3    English, man
```

The driver chooses between the two voices with the speaker button in drive mode,
which cycles woman → man → off. Nothing else is needed: `js/voice.js` looks for
exactly these names, and a language or a voice with no folder simply stays
silent. Adding the files is enough — no code change and no app release, only
`firebase deploy --only hosting:geocharge-tesla`.

## What is in there now

Generated with **Cartesia** (`sonic-3.5`, the one provider on the account that
speaks Georgian natively), then trimmed and loudness-normalised with ffmpeg:

| folder | voice | id |
| --- | --- | --- |
| `ka/f` | Woman AI voice Geo (Mziko) | `dc723fe8-a718-42b9-82a6-08ecbbb68fea` |
| `ka/m` | NLM voice MALE GEO | `d59f3f46-3342-4fb7-9a3c-e1e284b8d233` |
| `en/f` | Jessica - Clear Communicator | `25d7abcb-4d6d-4aca-adce-8a1c85620c8b` |
| `en/m` | Rowan - Steady Guide | `8c254787-4eb4-4577-bd3d-fb3c273baea2` |

The two Georgian ones are the account's own cloned voices. Re-generating in a
different voice is one pass over the table below with a new voice id.

## What to record

The wording matches `js/turn-phrases.js` on purpose: the voice and the banner
must not say different things.

| file | Georgian | English |
| --- | --- | --- |
| `in500` | ხუთას მეტრში | In five hundred metres |
| `in300` | სამას მეტრში | In three hundred metres |
| `in200` | ორას მეტრში | In two hundred metres |
| `in100` | ას მეტრში | In one hundred metres |
| `in50` | ორმოცდაათ მეტრში | In fifty metres |
| `left` | მოუხვიე მარცხნივ | Turn left |
| `right` | მოუხვიე მარჯვნივ | Turn right |
| `straight` | გააგრძელე პირდაპირ | Continue straight |
| `keepLeft` | დარჩი მარცხენა ზოლში | Keep left |
| `keepRight` | დარჩი მარჯვენა ზოლში | Keep right |
| `uturn` | მოტრიალდი | Make a U-turn |
| `roundabout` | შედი წრიულ მოძრაობაში | Enter the roundabout |
| `depart` | დაიწყე მოძრაობა | Start driving |
| `arrive` | ჩახვედი დანიშნულების ადგილას | You have arrived |
| `reroute` | მარშრუტი გადაითვალა | Route recalculated |

Sharp and slight turns are deliberately not recorded: out loud they are "turn
left" and "turn right", and the banner carries the exact wording for anyone
reading it.

## If you record them yourself instead

- Mono, mp3, 48–64 kbps is plenty; each clip is under two seconds.
- **Trim the silence at both ends.** The clips are played one after the other,
  and half a second of room tone in front of `right.mp3` is half a second of a
  driver waiting to be told where to go.
- Even loudness across all of them, and read the distance clips as if the
  maneuver follows — because it does.
- Keep one voice for the whole set, and the same voice in both languages if the
  same person can do both.
