# Daybreak data and story contract

This contract keeps dates, markets, provenance, offline behavior and recap statistics truthful.

## Sources

- `BingImageArchiveProvider` reads Bing `HPImageArchive.aspx` for recent image metadata, dates, markets, copyright and image URLs.
- `BingHomepageStoryProvider` may read the Bing homepage model for title, headline, description, quick fact, copyright and backstage URL.
- These endpoints are unofficial integration points. The app must tolerate missing history, missing markets, malformed responses, rate limits and redirects.

## Story policy

Store the original source field, source URL, source locale, fetch time, content hash and availability. A missing description is `storyUnavailable`; the app must never invent a story. Quick facts remain labelled as quick facts.

## Identity and joins

An image identity is separate from an occurrence. The same image can occur on multiple dates and in multiple markets. Join image and story records only when normalized date and market evidence agree. A one-day mismatch remains unmatched until a later reconciliation; it must not be silently attached.

Store the image date, market, fetch time and device time zone as separate values. Do not use the device time zone to rewrite the source date.

## Cache behavior

Metadata, thumbnails, original images and story text have independent cache lifetimes. A cached story remains readable when its original image is unavailable. Protected or user-favorited originals are excluded from automatic eviction. Concurrent requests for one asset resolve to one validated file.

Reject HTML, invalid content types, invalid image dimensions, blocked hosts and broken redirects. Keep the last valid asset when a replacement download fails.

## Recap behavior

Recaps count local observation and archive records only. They do not infer that an unobserved date had no Bing content. A saved image is counted once as a favorite even when it appears in several occurrences. Coverage and observed range remain visible when the local sample is small.

## Compliance

Bing images and story text remain owned by their rights holders. The repository contains synthetic or licensed fixtures only. Local caching does not grant redistribution or commercial-use rights.

## References

- https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=en-US
- https://github.com/wefashe/bing-image
- https://github.com/DIYgod/RSSHub/blob/master/lib/routes/bing/daily-wallpaper.ts
