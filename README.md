# Landmark — ellmer Agent Architecture (Draft)

> **Project goal:** Build an agentic AI using the **R ellmer** package that identifies Cleveland buildings from user input (name, address, or photo), retrieves authoritative historical and architectural information, and produces an illustrated, traceable narrative for users (researchers, tourists, preservationists).

---

## 1. High-level overview

This agent is a multi-tool, multi-step system designed to accept three primary input modes:

* **Text query** (building name, address, or partial description)
* **Image upload** (photo of a building facade, detail, or interior)
* **Geolocation / map click**

Core capabilities:

* Recognize buildings from images (via an image classification/embedding + nearest-neighbor search).
* Normalize and geocode textual addresses and place names.
* Query local authoritative sources (Cleveland Public Library archives, Cleveland Historical, Landmarks Commission, property records) and aggregate results.
* Synthesize and cite findings, produce timelines, related people, past photos, and map overlays.
* Offer suggested next actions (visit, contact archives, nominate for landmark status).

Agentic behavior (how the agent will act):

* Autonomously select which tools to call based on input modality and uncertainty.
* Iteratively retrieve and refine (e.g., when multiple candidate matches exist, ask a clarifying question or request a second photo).
* Cache and remember user preferences (e.g., favorite neighborhoods, preferred citation style).

---

## 2. Data sources & access patterns

Priority public/local sources (start here):

* Cleveland Public Library Digital Gallery — historical photos and metadata.
* Cleveland Historical — crowd-sourced local history pages and object records.
* Cleveland Landmarks Commission / City of Cleveland historic property inventories.
* Cuyahoga County property records (parcel data, year-built, tax records).
* Sanborn Fire Insurance maps (for historical footprints) — often available via library or LOC.
* Historic newspapers (via Chronicling America / local newspapers) for events and dates.
* Cleveland Museum of Art (for relevant architectural objects or archives).

Access patterns:

* Prefer direct API/JSON endpoints where available, otherwise rely on scraped or CSV downloads that are cached locally.
* Maintain a local archive (project DB) of harvested metadata and image thumbnails for quick lookups and image-embedding indices.

---

## 3. System components & tools (ellmer terminology)

### 3.1 Tools (what the agent can call)

* **geocode\_tool**: Geocode address/place → lat/lon + normalized address (uses local Nominatim or Census geocoder).
* **property\_lookup\_tool**: Query Cuyahoga County parcel API or cached CSV → returns parcel id, year built, owner (where public), architectural style tags.
* **archive\_search\_tool**: Query Cleveland Public Library / Cleveland Historical APIs by name/address/keywords → returns records with metadata and image URLs.
* **sanborn\_tool**: Lookup building footprint and historical map overlays by year (if available).
* **image\_search\_tool**: Reverse image search against local image index + Google/Bing image APIs (if available).
* **image\_recognition\_tool**: Run an image through a vision model to extract features — returns probable building IDs, architectural style labels, confidence scores, and suggested crop boxes.
* **ocr\_tool**: Extract text from uploaded photos (plaques, cornerstones, signage).
* **news\_search\_tool**: Search historic newspapers for events tied to address/name/date.
* **vector\_db\_search\_tool**: Nearest-neighbor search over image & text embeddings (for matching photos and textual similarity).
* **compose\_report\_tool**: Generate a human-readable report (markdown/HTML) with citations, timeline, and recommended follow-ups.
* **map\_visualization\_tool**: Produce interactive map tiles / Leaflet outputs for embedding in Shiny.
* **citation\_tool**: Format collected metadata into a consistent citation block.

### 3.2 Tools design notes

* Implement thin R wrappers for each external dependency so the ellmer agent can call them deterministically.
* Tools should return structured JSON with `status`, `candidates` (array), and `meta` (timestamps, source URIs).

---

## 4. Agent design: reasoning & control flow

### 4.1 Input handling

1. **Identify modality** (image vs text vs geolocation).
2. **Preprocessing**:

   * Image: run `ocr_tool` and `image_recognition_tool`; compute embeddings; detect faces/signs and redact if necessary.
   * Text: run entity extraction (address, building name, year) and geocode.
   * Location: run reverse-lookup for nearest parcels/buildings.

### 4.2 Candidate generation

* Use `property_lookup_tool`, `archive_search_tool`, and `vector_db_search_tool` to gather candidates.
* Rank candidates by a scoring function combining: geospatial distance, image similarity, textual match score, year plausibility.

### 4.3 Verification & disambiguation

* If top candidate score > threshold (e.g., 0.8), proceed to retrieval.
* If ambiguous, agent should do one of:

  * Ask the user a clarifying question (e.g., “Is this on Superior Ave or Euclid Ave?”).
  * Request an additional photo or crop region.
  * Present top 3 candidates with thumbnail images and let user pick.

### 4.4 Retrieval & synthesis

* For verified candidate, call `archive_search_tool`, `sanborn_tool`, and `news_search_tool` to fetch additional context.
* Build a timeline of events (construction, renovations, notable occurrences) using extracted dates.
* Generate an illustrated narrative: summary + key facts + gallery of historic images + map overlay.

### 4.5 Actions & suggestions

* The agent can propose next actions:

  * Download high-res images from CPL (follow licensing rules).
  * Contact the Landmarks Commission to request records.
  * Provide a printable walking-tour card with QR linking to the report.

---

## 5. Memory & user model

What to store:

* Short-term session memory: last N queries, recently inspected buildings.
* Long-term (opt-in): user favorite neighborhoods, preferred citation style, projects saved.
* Retrieval cache: normalized addresses, resolved parcels, and image embeddings for speed.

Privacy considerations:

* Do **not** store personally identifying uploads without explicit consent.
* Allow users to delete session data and opt out of analytics.

---

## 6. Prompting & LLM orchestration

* Use ellmer to define the agent with a **tool-first** system prompt. The LLM orchestrates which tools to call in which order.

* Example high-level system instruction (abbreviated):

  * You are the Historic Cleveland Building Detective. For each user request, decide the minimal set of tools to resolve identity, verify, retrieve authoritative sources, and produce a report. Always include source URIs and a confidence score.

* Use small modular prompts for each subtask (e.g., `summarize_images_prompt`, `synthesize_timeline_prompt`) to keep outputs focused.

---

## 7. UI / UX

Front-end choices:

* **Minimal demo**: Shiny app with upload box (image), query box, and interactive Leaflet map. Display generated report on the right, image gallery below.
* **Advanced demo**: Static website (pkgdown) + Shiny or a light React frontend (call R plumber endpoints).

UX patterns:

* Show progressive disclosure: quick summary up top, expandable sections for deep archival data.
* Present confidence and primary sources prominently.
* Enable users to flag errors and submit corrections (crowd-sourced vetting).

---

## 8. Evaluation & testing

Metrics to track:

* **Identification accuracy** on a labeled test set (images + ground-truth building IDs).
* **Precision\@k** for top-3 candidate lists.
* **User satisfaction** from small pilot with local historians.
* **Latency** for common queries.

Test datasets:

* Hand-curated set of 100 Cleveland buildings spanning era/style/neighborhood.
* Use historical postcards and current street-view photos for robustness.

---

## 9. Tech stack & implementation roadmap

### Core stack

* **R**: ellmer (agent orchestration), plumber (API endpoints), Shiny (demo UI), sf (spatial), httr / jsonlite (APIs), {reticulate} if you need Python vision models.
* **Vector DB**: FAISS (local) or Milvus for embeddings (image+text).
* **Image models**: Use a pre-trained CLIP-style embedding model (via Python/reticulate or an R binding) for image↔text matching.
* **Database**: SQLite or Postgres for harvested metadata and cache.

### Roadmap (phased)

1. **MVP (2–3 weeks)**

   * Build data harvester for CPL + Cleveland Historical + parcel CSV import.
   * Create local image index (embeddings) and small vector DB.
   * Implement `geocode_tool`, `archive_search_tool`, `image_recognition_tool` wrappers.
   * Make a simple Shiny UI: upload image → display top candidate + basic metadata.

2. **Phase 2 (4–6 weeks)**

   * Add SANBORN overlays, OCR workflow, and historic newspaper lookups.
   * Improve ranking and add disambiguation dialogs.
   * Add exportable report feature.

3. **Phase 3 (optional polish)**

   * Implement user accounts & long-term memory (opt-in).
   * Add walking-tour generator and printable cards.
   * Run pilot with local historical society and gather feedback.

---

## 10. Example ellmer agent skeleton (pseudocode)

```r
library(ellmer)

tools <- list(
  geocode = tool_geocode(),
  lookup_property = tool_property_lookup(),
  search_archives = tool_archive_search(),
  image_recognize = tool_image_recognition(),
  vector_search = tool_vector_search(),
  compose = tool_compose_report()
)

agent <- ellmer_agent(
  model = "gpt-4o-mini", # example
  tools = tools,
  system_prompt = read_file("prompts/system_detective.txt")
)

# Sample run (image input):
result <- agent$run(list(input_mode = "image", image_path = "uploads/arcade.jpg"))
```

---

## 11. Failure modes & mitigation

* **Wrong building match**: present top N candidates and confidence; ask for disambiguation.
* **Bad or missing metadata**: surface provenance and gaps; suggest next actions for archival lookup.
* **Image with privacy-sensitive content**: auto-redact faces and personal info; inform user.
* **Rate-limits / broken APIs**: use cached copy of harvested data and graceful degradation.

---

## 12. Next steps (what I can do for you next)

* Convert this draft into a runnable ellmer agent script with concrete tool implementations.
* Build the MVP Shiny demo and sample dataset of \~50 Cleveland buildings to evaluate accuracy.
* Help set up the image embedding pipeline and vector DB (FAISS) with example code.

If you'd like, I can begi
