#!/usr/bin/env Rscript
# Download hex stickers for every CRAN package using hexFinder's search logic.
#
# Usage:
#   Rscript download_hexes.R            # all CRAN packages
#   Rscript download_hexes.R 20         # first 20 packages only
#   Rscript download_hexes.R ggplot2 dplyr   # named packages only
#   Rscript download_hexes.R --no-optipng 20 # skip PNG optimisation
#
# Output: raw/PKG.png (always, when a hex is found) and raw/PKG.svg
# (when an SVG exists upstream). Progress is recorded in raw/manifest.csv,
# so the script can be stopped and restarted. PNGs are losslessly
# optimised with optipng (if installed) unless --no-optipng is given.

suppressPackageStartupMessages({
  library(hexFinder)
  library(magick)
})

options(repos = c(CRAN = "https://cloud.r-project.org"), timeout = 60)

out_dir <- "raw"
manifest_path <- file.path(out_dir, "manifest.csv")
png_width <- 600
dir.create(out_dir, showWarnings = FALSE)

hf <- asNamespace("hexFinder")
token <- Sys.getenv("github_pat", Sys.getenv("GITHUB_PAT"))

msg <- function(...) {
  cat(format(Sys.time(), "%H:%M:%S"), ..., "\n")
  flush.console()
}

# ---- Package list -----------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
skip_optipng <- "--no-optipng" %in% args
args <- setdiff(args, "--no-optipng")
use_optipng <- !skip_optipng && nzchar(Sys.which("optipng"))
if (!skip_optipng && !use_optipng) {
  msg("optipng not found on PATH - PNGs will not be optimised")
}
pkgs <- rownames(available.packages())
if (length(args) == 1 && grepl("^[0-9]+$", args)) {
  pkgs <- head(pkgs, as.integer(args))
} else if (length(args) > 0) {
  pkgs <- args
}

meta <- tools::CRAN_package_db()
meta <- meta[!duplicated(meta$Package), c("Package", "URL", "BugReports")]
rownames(meta) <- meta$Package

# ---- Manifest ---------------------------------------------------------------

done <- character()
if (file.exists(manifest_path)) {
  manifest <- read.csv(manifest_path, stringsAsFactors = FALSE)
  # Last row per package wins; errors are retried
  manifest <- manifest[!duplicated(manifest$package, fromLast = TRUE), ]
  # A package left "pending" killed the process (e.g. an ImageMagick abort):
  # record it as a crash and don't try it again
  crashed <- manifest$package[manifest$status == "pending"]
  done <- manifest$package[manifest$status %in% c("found", "none", "crash")]
}

record <- function(pkg, status, source_url = "", files = "") {
  row <- data.frame(
    package = pkg, status = status, source_url = source_url,
    files = files, time = format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  )
  write.table(row, manifest_path,
    sep = ",", row.names = FALSE, qmethod = "double",
    append = file.exists(manifest_path),
    col.names = !file.exists(manifest_path)
  )
}

if (exists("crashed")) {
  for (pkg in crashed) {
    msg("Previous run crashed on", pkg, "- skipping it")
    unlink(file.path(out_dir, paste0(pkg, c(".png", ".svg", ".jpg", ".jpeg"))))
    record(pkg, "crash")
  }
  done <- c(done, crashed)
}

# ---- GitHub rate limit ------------------------------------------------------
# hexFinder swallows HTTP errors, so a 403 would look like "no logo".
# Check the quota ourselves (the rate_limit endpoint is free) and wait it out.

rate <- list(remaining = 0, reset = 0, checked = 0)

wait_for_rate_limit <- function(since_check) {
  if (rate$remaining - since_check > 20 && since_check < 50) {
    return(invisible())
  }
  req <- httr2::request("https://api.github.com/rate_limit")
  if (nzchar(token)) {
    req <- httr2::req_headers(req, Authorization = paste("Bearer", token))
  }
  core <- httr2::resp_body_json(httr2::req_perform(req))$resources$core
  rate$remaining <<- core$remaining
  rate$reset <<- core$reset
  if (core$remaining < 20) {
    wait <- max(0, core$reset - as.numeric(Sys.time())) + 5
    msg(sprintf("Rate limit low (%d left). Sleeping %.0f s", core$remaining, wait))
    Sys.sleep(wait)
    rate$remaining <<- core$limit
  }
  rate$checked <<- 0
}

# ---- Finding URLs -----------------------------------------------------------

find_logo_url <- function(pkg) {
  url <- hf$check_known_packages(pkg)
  if (!is.null(url)) return(url)

  url <- hf$check_known_repos(pkg)
  if (!is.null(url)) return(url)

  links <- if (pkg %in% rownames(meta)) {
    hf$clean_repo_links(meta[pkg, "URL"], meta[pkg, "BugReports"])
  }
  repo <- if (length(links) > 0) links[1] else paste0("https://github.com/cran/", pkg)

  wait_for_rate_limit(rate$checked)
  rate$checked <<- rate$checked + 2 # master + main
  hf$search_repo_logo(pkg, repo, token = token)
}

# Given the found URL, guess where the other format might live
sibling_urls <- function(url) {
  ext <- tolower(tools::file_ext(url))
  other <- switch(ext, svg = "png", png = "svg", character())
  if (length(other) == 0) return(character())

  swapped <- sub(paste0("\\.", tools::file_ext(url), "$"), paste0(".", other), url)
  known <- c(
    sub("/SVG/([^/]+)\\.svg$", "/PNG/\\1.png", url),
    sub("/PNG/([^/]+)\\.png$", "/SVG/\\1.svg", url),
    sub("/vector/([^/]+)\\.svg$", "/hexagons/\\1.png", url),
    sub("/hexagons/([^/]+)\\.png$", "/vector/\\1.svg", url)
  )
  unique(setdiff(c(swapped, known), url))
}

# ---- Download and normalise -------------------------------------------------

download_one <- function(pkg, url) {
  ext <- tolower(tools::file_ext(url))
  # Never crop SVGs: magick would rewrite them as rasters
  path <- hf$download_logo(pkg, url, out_dir, crop = ext != "svg")
  target <- file.path(out_dir, paste0(pkg, ".", ext))
  if (path != target) file.rename(path, target)

  # Some servers return a JPEG behind a .png URL, so check the actual format
  if (ext != "svg") {
    img <- image_read(target)
    if (ext != "png" || image_info(img)$format != "PNG") {
      png_path <- file.path(out_dir, paste0(pkg, ".png"))
      image_write(img, png_path, format = "png")
      if (target != png_path) unlink(target)
      target <- png_path
    }
  }
  target
}

optimise_png <- function(path) {
  if (!use_optipng || !file.exists(path)) return(invisible())
  system2("optipng", c("-quiet", "-o2", "-strip", "all", shQuote(path)),
    stdout = FALSE, stderr = FALSE
  )
}

valid_image <- function(path) {
  info <- tryCatch(image_info(hf$image_reader(path)), error = function(e) NULL)
  !is.null(info) && info$width > 0
}

process <- function(pkg) {
  url <- find_logo_url(pkg)
  if (is.null(url)) {
    record(pkg, "none")
    return("none")
  }

  urls <- url
  for (s in sibling_urls(url)) {
    if (hf$url_file_exists(s)) {
      urls <- c(urls, s)
      break
    }
  }

  files <- character()
  for (u in urls) {
    f <- tryCatch(download_one(pkg, u), error = function(e) NULL)
    if (!is.null(f) && valid_image(f)) {
      files <- c(files, f)
    } else if (!is.null(f)) {
      unlink(f)
    }
  }

  svg <- file.path(out_dir, paste0(pkg, ".svg"))
  png <- file.path(out_dir, paste0(pkg, ".png"))
  if (svg %in% files && !png %in% files) {
    img <- image_trim(image_read_svg(svg, width = png_width))
    image_write(img, png, format = "png")
    files <- c(files, png)
  }
  optimise_png(png)

  if (length(files) == 0) {
    record(pkg, "error", paste(urls, collapse = " "))
    return("error")
  }
  record(pkg, "found", paste(urls, collapse = " "), paste(basename(files), collapse = " "))
  "found"
}

# ---- Main loop --------------------------------------------------------------

todo <- setdiff(pkgs, done)
msg(sprintf("%d packages, %d already done, %d to process", length(pkgs), length(done), length(todo)))

counts <- c(found = 0, none = 0, error = 0)
for (i in seq_along(todo)) {
  pkg <- todo[i]
  record(pkg, "pending")
  status <- tryCatch(
    R.utils::withTimeout(process(pkg), timeout = 120, onTimeout = "error"),
    error = function(e) {
      msg("Error for", pkg, ":", conditionMessage(e))
      record(pkg, "error")
      "error"
    }
  )
  counts[status] <- counts[status] + 1
  msg(sprintf("[%d/%d] %s: %s", i, length(todo), pkg, status))
}

msg("Done:", paste(names(counts), counts, sep = "=", collapse = ", "))
