library(httr)
library(jsonlite)
library(dplyr)
library(readr)
library(sf)
library(glue)
library(stringr)
library(purrr)
library(magrittr)
library(leaflet)
library(base64enc)

# Optional: reticulate for Python-based embeddings
have_reticulate <- requireNamespace("reticulate", quietly = TRUE)
if (have_reticulate) {
  reticulate::use_virtualenv(".venv", required = FALSE)
}

# -----------------------------
# Helper: standardized tool return
# -----------------------------

tool_response <- function(status = "ok", candidates = list(), meta = list()) {
  list(status = status, candidates = candidates, meta = meta)
}

# -----------------------------
# Tool: geocode_tool (Nominatim)
# -----------------------------

tool_geocode <- function(user_agent = "cle-historic-agent/1.0") {
  function(q) {
    # q: list(query = "123 Main St, Cleveland")
    query <- q$query
    url <- "https://nominatim.openstreetmap.org/search"
    res <- httr::GET(url, query = list(q = query, format = "json", limit = 5), httr::user_agent(user_agent))
    if (res$status_code != 200) return(tool_response("error", list(), list(http_status = res$status_code)))
    parsed <- jsonlite::fromJSON(httr::content(res, as = "text", encoding = "UTF-8"))
    candidates <- purrr::map(parsed, function(r) list(display_name = r$display_name, lat = as.numeric(r$lat), lon = as.numeric(r$lon), type = r$type, importance = r$importance))
    tool_response("ok", candidates, meta = list(source = "nominatim", query = query))
  }
}

# -----------------------------
# Tool: property_lookup_tool (local CSV fallback)
# -----------------------------

tool_property_lookup <- function(parcels_path = "data/parcels.csv") {
  parcels <- if (file.exists(parcels_path)) readr::read_csv(parcels_path, show_col_types = FALSE) else tibble::tibble()
  function(q) {
    # q: list(lat=..., lon=..., address = '...')
    if (nrow(parcels) == 0) return(tool_response("empty", list(), list(msg = "no parcels loaded")))
    if (!is.null(q$address)) {
      adr <- tolower(q$address)
      matches <- parcels %>% filter(str_detect(tolower(address), fixed(adr)))
    } else if (!is.null(q$lat) && !is.null(q$lon)) {
      pts <- st_as_sf(parcels, coords = c("lon", "lat"), crs = 4326)
      p <- st_sfc(st_point(c(q$lon, q$lat)), crs = 4326)
      d <- sf::st_distance(pts, p)
      idx <- which.min(as.numeric(d))
      matches <- parcels[idx, , drop = FALSE]
    } else {
      return(tool_response("error", list(), list(msg = "no address or lat/lon provided")))
    }
    candidates <- purrr::pmap(as.list(matches), function(...) list(...))
    tool_response("ok", candidates, meta = list(source = "local_parcels", n = length(candidates)))
  }
}

# -----------------------------
# Tool: archive_search_tool (local CSV + HTTP fallback)
# -----------------------------

tool_archive_search <- function(archives_path = "data/archives.csv") {
  archives <- if (file.exists(archives_path)) readr::read_csv(archives_path, show_col_types = FALSE) else tibble::tibble()
  function(q) {
    # q: list(query = "Arcade", address = NULL, lat = NULL)
    if (nrow(archives) > 0 && !is.null(q$query)) {
      qry <- tolower(q$query)
      found <- archives %>% filter(str_detect(tolower(title), fixed(qry)) | str_detect(tolower(address), fixed(qry)))
      candidates <- purrr::pmap(as.list(found), function(...) list(...))
      return(tool_response("ok", candidates, meta = list(source = "local_archives", n = length(candidates))))
    }
    # Fallback: generic Cleveland Historical search (no API key required example)
    if (!is.null(q$query)) {
      # NOTE: this is a simple web scrape placeholder; for production use, implement proper API harvesting
      return(tool_response("ok", list(), meta = list(source = "none", msg = "no local archives; implement remote harvest")))
    }
    tool_response("error", list(), meta = list(msg = "no query provided"))
  }
}

# -----------------------------
# Tool: image_recognition_tool (CLIP-style embeddings via Python optional)
# -----------------------------

tool_image_recognition <- function(embeddings_path = "data/image_embeddings.rds", images_dir = "data/images") {
  # embeddings_path: precomputed image embeddings (list of ids + vectors)
  embeddings <- if (file.exists(embeddings_path)) readRDS(embeddings_path) else NULL
  
  # If reticulate available, load python embedding model
  py_embed <- NULL
  if (have_reticulate) {
    try({
      sbert <- reticulate::import('sentence_transformers', convert = FALSE)
      model <- sbert$SentenceTransformer('clip-ViT-B-32')
      py_embed <- function(img_path) {
        # read image bytes in python and embed
        pil <- reticulate::import('PIL.Image')
        img <- pil$open(img_path)
        arr <- model$encode(img)
        as.numeric(arr)
      }
    }, silent = TRUE)
  }
  
  function(q) {
    # q: list(image_path = 'uploads/xxx.jpg')
    if (is.null(q$image_path)) return(tool_response("error", list(), meta = list(msg = "no image provided")))
    if (!is.null(py_embed) && !is.null(embeddings)) {
      vec <- py_embed(q$image_path)
      # find nearest neighbor in embeddings (brute force)
      mats <- do.call(rbind, embeddings$vectors)
      dists <- as.numeric(apply(mats, 1, function(r) sum((r - vec)^2)))
      idx <- order(dists)[1:5]
      candidates <- lapply(idx, function(i) list(id = embeddings$ids[[i]], score = 1 / (1 + dists[i]), meta = list(src = 'local_image_index')))
      return(tool_response('ok', candidates, meta = list(n = length(candidates))))
    }
    # fallback: return empty candidates but attempt OCR
    return(tool_response('empty', list(), meta = list(msg = 'no image embedding backend available')))
  }
}

# -----------------------------
# Tool: ocr_tool (Tesseract local via tesseract CLI assumed)
# -----------------------------

tool_ocr <- function() {
  function(q) {
    if (is.null(q$image_path)) return(tool_response('error', list(), meta = list(msg = 'no image')))
    img <- q$image_path
    # Use tesseract via system call if available
    if (Sys.which('tesseract') != '') {
      tmp <- tempfile(fileext = '.txt')
      cmd <- glue::glue('tesseract "{img}" "{tools::file_path_sans_ext(tmp)}"')
      system(cmd, ignore.stdout = TRUE, ignore.stderr = TRUE)
      txt <- tryCatch(readr::read_file(paste0(tools::file_path_sans_ext(tmp), '.txt')), error = function(e) '')
      return(tool_response('ok', list(text = txt), meta = list(source = 'tesseract')))
    }
    tool_response('empty', list(), meta = list(msg = 'tesseract not installed'))
  }
}

# -----------------------------
# Tool: vector_db_search_tool (local RDS fallback)
# -----------------------------

tool_vector_search <- function(embeddings_path = 'data/text_embeddings.rds') {
  embeddings <- if (file.exists(embeddings_path)) readRDS(embeddings_path) else NULL
  function(q) {
    if (is.null(q$query)) return(tool_response('error', list(), meta = list(msg = 'no query')))
    if (is.null(embeddings)) return(tool_response('empty', list(), meta = list(msg = 'no embeddings loaded')))
    # naive cosine similarity
    vec <- q$query_vector
    mats <- do.call(rbind, embeddings$vectors)
    sims <- as.numeric(mats %*% vec / (sqrt(rowSums(mats^2)) * sqrt(sum(vec^2))))
    idx <- order(-sims)[1:min(10, nrow(mats))]
    candidates <- lapply(idx, function(i) list(id = embeddings$ids[[i]], score = sims[i], meta = list()))
    tool_response('ok', candidates, meta = list(n = length(candidates)))
  }
}

# -----------------------------
# Tool: compose_report_tool (Markdown)
# -----------------------------

tool_compose_report <- function() {
  function(q) {
    # q: list(candidate = <list with fields>)
    c <- q$candidate
    if (is.null(c)) return(tool_response('error', list(), meta = list(msg = 'no candidate')))
    md <- c('# Historic Building Report

')
    md <- paste0(md, glue::glue('**Title / Name:** {ifelse(!is.null(c$title), c$title, "Unknown")}

'))
    md <- paste0(md, glue::glue('**Address:** {ifelse(!is.null(c$address), c$address, "Unknown")}

'))
    md <- paste0(md, glue::glue('**Year built:** {ifelse(!is.null(c$year), c$year, "Unknown")}

'))
    md <- paste0(md, '
**Sources:**
')
    if (!is.null(c$source)) md <- paste0(md, glue::glue('- {c$source}
'))
    if (!is.null(c$url)) md <- paste0(md, glue::glue('- {c$url}
'))
    tool_response('ok', list(report_markdown = md), meta = list(length = nchar(md)))
  }
}


historic_detective_agent <- function(tools) {
  # tools: list of functions
  agent <- list()
  
  agent$run <- function(req) {
    # req: list(input_mode = 'text'|'image'|'location', query=..., image_path=..., lat=..., lon=...)
    input_mode <- req$input_mode %||% 'text'
    
    # 1. Preprocess
    if (input_mode == 'text') {
      q <- req$query
      geores <- tools$geocode(list(query = q))
      # if exact match in local archives
      archives <- tools$search_archives(list(query = q))
      props <- NULL
      if (length(geores$candidates) > 0) {
        best <- geores$candidates[[1]]
        props <- tools$lookup_property(list(lat = best$lat, lon = best$lon))
      }
      # candidate consolidation: prefer archives match, else property match
      candidate <- NULL
      if (length(archives$candidates) > 0) candidate <- archives$candidates[[1]] else if (!is.null(props) && length(props$candidates) > 0) candidate <- props$candidates[[1]]
      
      if (is.null(candidate)) return(list(status = 'no_match', meta = list(geocode = geores, archives = archives)))
      
      report <- tools$compose(list(candidate = candidate))
      return(list(status = 'success', candidate = candidate, report = report$candidates[[1]]$report_markdown))
      
    } else if (input_mode == 'image') {
      # run OCR
      ocr <- tools$ocr(list(image_path = req$image_path))
      # run image recognition
      ir <- tools$image_recognize(list(image_path = req$image_path))
      # if image recognition returned candidates, fetch archive info
      if (length(ir$candidates) > 0) {
        top <- ir$candidates[[1]]
        # attempt to find archive record by id
        archives <- tools$search_archives(list(query = top$id))
        candidate <- if (length(archives$candidates) > 0) archives$candidates[[1]] else list(id = top$id, title = NULL, address = NULL, year = NULL, source = 'image_index')
        report <- tools$compose(list(candidate = candidate))
        return(list(status = 'success', candidate = candidate, report = report$candidates[[1]]$report_markdown, ocr = ocr))
      }
      return(list(status = 'no_match', meta = list(ocr = ocr, image_recog = ir)))
    } else if (input_mode == 'location') {
      # Reverse lookup: find parcel for lat/lon
      props <- tools$lookup_property(list(lat = req$lat, lon = req$lon))
      if (length(props$candidates) == 0) return(list(status = 'no_match'))
      candidate <- props$candidates[[1]]
      report <- tools$compose(list(candidate = candidate))
      return(list(status = 'success', candidate = candidate, report = report$candidates[[1]]$report_markdown))
    }
    list(status = 'error', meta = list(msg = 'unsupported input mode'))
  }
  agent
}

# -----------------------------
# Wiring up tools with defaults
# -----------------------------

tools <- list(
  geocode = tool_geocode(),
  lookup_property = tool_property_lookup('data/parcels.csv'),
  search_archives = tool_archive_search('data/archives.csv'),
  image_recognize = tool_image_recognition('data/image_embeddings.rds', 'data/images'),
  ocr = tool_ocr(),
  vector_search = tool_vector_search('data/text_embeddings.rds'),
  compose = tool_compose_report()
)

agent <- historic_detective_agent(tools)

# Example: text run
# res <- agent$run(list(input_mode = 'text', query = 'The Arcade Cleveland'))
# print(res$status)
# cat(res$report)

# Example: location run
# res2 <- agent$run(list(input_mode = 'location', lat = 41.5089, lon = -81.6954))
# print(res2)
