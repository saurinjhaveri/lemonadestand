# AI Tour Guide on Meta Ray-Ban Glasses — Build Plan

A practical plan to turn Meta Ray-Ban (Gen 2) glasses into a hands-free,
ChatGPT-powered tour guide: you speak, it answers; you look at a building,
painting, or statue, snap a photo, and it identifies the thing (using the
**image + your GPS location**) and tells you fun facts, stories, what's
unmissable, and what's a tourist trap to skip.

> **Decision summary:** Build a native **iOS (Swift)** app that uses Meta's
> **Wearables Device Access Toolkit** for the glasses' camera/audio, the
> **phone's GPS** for location, **OpenAI** (GPT vision + Realtime voice) for
> reasoning/narration, and **Google Places** to ground landmark identification.
> The old "route through WhatsApp" hack is dead as of 2026 — don't use it.

---

## 1. Reality check (what changed in 2026)

Two developments define what's possible:

### ✅ Meta now has an official SDK for this exact use case
The **Meta Wearables Device Access Toolkit (DAT)** (developer preview, 2026)
lets a phone app access the glasses':
- **12 MP ultra-wide camera** — photo capture **and** live video streaming
- **5-mic array** (audio in) and **open-ear speakers** (audio out), via standard
  iOS/Android Bluetooth audio profiles

Supported hardware: **Ray-Ban Meta Gen 1 & Gen 2**, Oakley Meta HSTN.
Official SDKs: `facebook/meta-wearables-dat-ios` and `facebook/meta-wearables-dat-android` on GitHub.

**Status caveats (important):**
- You can **build and test on your own glasses today** during the preview.
- **Public App Store publishing is gated** to "select partners"; general
  availability is targeted for later in 2026. So this is buildable *for
  yourself now*, shippable-to-the-world *soon*.
- The **"Hey Meta" wake word is NOT available to third parties** this year.
  You cannot fully replace Meta's assistant with your own wake word on the
  glasses. You trigger your experience from the **phone app** instead (physical
  capture button, your own wake-word detector, or always-listening mic).
- The glasses' camera is reached through the DAT; the **mic and speakers are
  reached as a normal Bluetooth headset**.

### ❌ The old WhatsApp/Messenger bridge is dead
The popular "Hey Meta, send a message to ChatGPT" trick routed messages through
WhatsApp/Messenger to a bot. **Meta banned third-party general-purpose AI
chatbots (ChatGPT, Perplexity, etc.) from the WhatsApp Business API as of
January 2026.** Every tutorial using that approach is now obsolete. Skip it.

### Consequence for the design
Because the app runs on the **phone** (glasses = camera + headset), you get the
**phone's GPS for free**. The glasses don't expose location themselves, so this
phone-centric design is actually the *right* one for a location-aware tour guide.

---

## 2. Architecture

```
        Meta Ray-Ban Gen 2
   ┌──────────────────────────────┐
   │  12MP camera   5 mics   spkrs │
   └───────┬───────────┬──────────┘
           │ DAT       │ Bluetooth audio (HFP/A2DP)
           │ (camera/  │ (mic in, TTS out)
           │  video)   │
           ▼           ▼
   ┌──────────────────────────────────────────┐
   │            iOS app (Swift)                │
   │  • Meta DAT session (capture photo/frame) │
   │  • CoreLocation → GPS lat/long            │
   │  • Wake-word / push-to-talk trigger       │
   │  • Streams mic audio + photo + location   │
   └───────────────────┬──────────────────────┘
                       │ HTTPS / WebSocket
                       ▼
   ┌──────────────────────────────────────────┐
   │        Backend "Brain" (cloud)            │
   │                                            │
   │  1. Reverse-geocode + Google Places        │
   │     Nearby Search → candidate landmarks    │
   │  2. OpenAI GPT vision (Responses API):     │
   │     photo + candidates + GPS → identify    │
   │  3. OpenAI reasoning → fun facts, stories, │
   │     "don't miss" vs "skip this"            │
   │  4. (optional) Wikipedia/Wikidata grounding│
   │  5. TTS (or OpenAI Realtime for live voice)│
   └───────────────────┬──────────────────────┘
                       │ audio / text
                       ▼
             Played through glasses speakers
```

**Why combine image + GPS?** Pure vision *guesses* ("looks like a Gothic
cathedral"). GPS + Google Places *confirms* ("you're at the Duomo di Milano").
Feeding both to the model is what makes identification reliable.

### Two interaction modes
1. **"Look at this" (photo):** trigger → DAT captures a frame → backend does
   Places + vision ID → narrates facts/stories. Best for buildings, paintings,
   statues.
2. **"Talking guide" (conversation):** continuous low-latency voice chat for
   "what should I not miss here?", "is this museum worth it?", planning, etc.
   Best served by **OpenAI Realtime API** so it feels like a real guide.

---

## 3. The API / service stack

| Need | Service | Notes |
|------|---------|-------|
| Glasses camera + video | **Meta Wearables Device Access Toolkit (iOS)** | `facebook/meta-wearables-dat-ios`; requires Meta developer registration + GitHub-gated SDK access |
| Glasses mic + speaker | **Bluetooth (AVAudioSession)** | Glasses act as a standard BT headset; no special SDK |
| Phone location | **CoreLocation** | `CLLocationManager`, lat/long + heading |
| Landmark identification | **Google Places API** (Nearby Search + Place Details) | Grounds "what is this" by coordinates; reviews/ratings power "skip vs unmissable" |
| Optional 2nd vision signal | **Google Cloud Vision** (landmark detection) | Extra confidence for famous landmarks |
| Image understanding + reasoning | **OpenAI Responses API** (GPT-4o / latest GPT-5-class vision model) | Photo + candidate names + GPS → ID + narration |
| Live voice conversation | **OpenAI Realtime API** | Low-latency speech-to-speech tour-guide chat |
| Text-to-speech (if not Realtime) | **OpenAI TTS** (or ElevenLabs for nicer voices) | Plays back through glasses speakers |
| Fact grounding (optional) | **Wikipedia / Wikidata REST APIs** | Reduces hallucinated "facts" |
| Custom wake word (optional) | **Picovoice Porcupine** | On-device "Hey Guide" since "Hey Meta" is off-limits |

You do **not** strictly need a cloud server to start — the iOS app can call
OpenAI and Google directly. But a thin backend is recommended so your API keys
never ship inside the app, and so you can cache/curate results. Start simple
(direct calls), add the backend before sharing the app with anyone.

---

## 4. Phased roadmap

### Phase 0 — Working *today*, zero code (stopgap)
Pair the glasses as a Bluetooth headset → open the **ChatGPT app → Advanced
Voice Mode** → talk through the glasses. Instant conversational tour guide.
Limitation: **no live camera, no automatic location.** Use this while building.

### Phase 1 — Foundations (the talking guide)
- Apply for the **Meta Wearables Device Access Toolkit** developer preview;
  register your app; get SDK access.
- New iOS app; integrate `meta-wearables-dat-ios`; establish a glasses session;
  confirm you can **capture a photo** from the glasses.
- Wire **CoreLocation** for GPS.
- Add **OpenAI Realtime** voice over the glasses' BT mic/speaker → you can now
  *talk* to the guide hands-free (push-to-talk or your own wake word).
- **Milestone:** ask "what's worth seeing near me?" and hear a grounded answer
  (Realtime + Places, no photo yet).

### Phase 2 — "Look at this" vision
- On trigger, capture a frame via DAT, get GPS, call backend.
- Backend: Google Places Nearby Search → candidate landmarks → OpenAI vision
  (photo + candidates + coords) → identify + narrate.
- Tune the **system prompt / persona** (see §6) for fun facts, stories, and the
  "don't miss / avoid" judgments.
- **Milestone:** point at a statue, snap, hear "That's …, and here's the wild
  story behind it…"

### Phase 3 — Polish & guide intelligence
- "Plan my next 2 hours here" itineraries; "what's a tourist trap nearby?"
- Wikipedia/Wikidata grounding to cut hallucinations; cache landmark results.
- Conversation memory (what you've already seen today) for continuity.
- Offline/poor-signal fallbacks; cost controls (see §5).

### Phase 4 — Sharing / shipping
- Move all keys behind the backend; add auth + rate limiting.
- Pursue Meta's partner publishing path when GA opens (preview only allows
  sharing builds within your own org/testers).

---

## 5. Cost expectations (ballpark — verify current pricing)

> Pricing changes frequently; treat these as order-of-magnitude. Check each
> provider's current rates before committing.

- **OpenAI Realtime (voice):** the priciest piece — billed per audio token,
  roughly on the order of cents per minute of conversation. Use a smaller/mini
  realtime model and only stream when actually talking. Consider STT→text
  GPT→TTS instead of full Realtime if cost matters more than latency.
- **OpenAI vision (per photo):** typically a few cents per image analysis
  depending on resolution. Downscale frames before sending.
- **Google Places:** Nearby Search and Place Details are a few dollars per 1,000
  calls, with a recurring monthly free credit that likely covers personal use.
- **TTS (if separate):** cheap, ~dollars per million characters.

For **personal use**, expect single-digit dollars per day of heavy touring.
Add caching (same landmark = reuse the narration) to keep it low.

---

## 6. Persona prompt (starting point for the guide's voice)

Use a system prompt like this for the reasoning/vision calls:

```
You are an expert local tour guide — warm, funny, and concise. You receive a
photo the user is looking at, their GPS coordinates, and a shortlist of nearby
landmarks. Identify what they're seeing by combining the image with the
location (prefer the location-confirmed candidate over a pure visual guess; say
so if you're unsure). Then, in ~30–45 seconds of spoken-style narration:
- Say what it is in one vivid sentence.
- Give 2–3 genuinely interesting facts or a short story (not a Wikipedia dump).
- End with practical guide advice for THIS spot: what's unmissable here, and
  what's overrated/avoidable (tourist traps, long lines not worth it, better
  alternatives nearby).
Keep it conversational for text-to-speech. No bullet points, no headers. If you
can't identify it confidently, say what it likely is and ask one quick question.
```

Tune length for spoken output; long answers feel slow through earpieces.

---

## 7. Key risks & mitigations

| Risk | Mitigation |
|------|-----------|
| Can't publish to public yet (partner-gated) | Build for yourself now; it works on your own glasses in preview. Pursue partner publishing at GA. |
| No third-party "Hey Meta" wake word | Use push-to-talk, the glasses' capture button, or your own wake word (Porcupine). |
| Vision misidentifies landmarks | Always ground with GPS + Google Places; have the model express uncertainty. |
| Hallucinated "fun facts" | Ground with Wikipedia/Wikidata; instruct the model to flag low confidence. |
| Voice latency feels laggy | Use OpenAI Realtime; downscale images; cache repeat landmarks. |
| API costs creep up | Cache by landmark, downscale frames, stream voice only while talking, use mini models. |
| API keys in the app | Put a thin backend in front before sharing the app with anyone. |

---

## 8. Immediate next actions

1. **Today:** Try Phase 0 (ChatGPT Advanced Voice Mode over the glasses' BT) to
   feel the "talking guide" half immediately.
2. **This week:** Apply for the **Meta Wearables Device Access Toolkit** preview
   and an **OpenAI API** key; create a **Google Cloud** project with Places API
   enabled.
3. **Then:** Start the iOS app (Phase 1) — DAT session + photo capture + GPS +
   Realtime voice.

---

## Sources

- [Introducing the Meta Wearables Device Access Toolkit — Meta for Developers](https://developers.meta.com/blog/introducing-meta-wearables-device-access-toolkit/)
- [Meta Launches Developer Preview for Wearables Toolkit — Auganix](https://www.auganix.org/ar-news-meta-wearable-device-sdk/)
- [New Meta Developer Tool Enables Third-parties to Bring Apps to its Smart Glasses — Road to VR](https://roadtovr.com/meta-ray-ban-smart-glasses-third-party-app-sdk-device-access-toolkit/)
- [Meta's Smart Glasses SDK Is Now Available To Build With, But Not Yet To Ship — UploadVR](https://www.uploadvr.com/meta-wearables-device-access-toolkit-public-preview/)
- [Meta Wearables Developer Documentation](https://wearables.developer.meta.com/docs)
- [Meta Wearables Device Access Toolkit FAQ — Meta for Developers](https://developers.meta.com/wearables/faq/)
- [facebook/meta-wearables-dat-ios — GitHub](https://github.com/facebook/meta-wearables-dat-ios)
- [facebook/meta-wearables-dat-android — GitHub](https://github.com/facebook/meta-wearables-dat-android)
- [Meta will ban rival AI chatbots from WhatsApp — TechRadar](https://techradar.com/ai-platforms-assistants/meta-will-ban-rival-ai-chatbots-from-whatsapp)
- [Meta bans third-party LLM chatbots in WhatsApp — GSMArena](https://m.gsmarena.com/meta_bans_thirdparty_llm_chatbots_in_whatsapp_-amp-70460.php)
