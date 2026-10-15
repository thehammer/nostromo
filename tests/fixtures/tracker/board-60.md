# Synthetic release triage

Synthetic board used by the tracker engine tests. Every name, id and number in it is invented.

## Now
- [ ] Check referral 4411 duplicate — in progress · 14:53 <!-- #check-1000 1760540000 -->
  Seen on host 14, see the log for detail
  Links: [PR #253](https://github.com/example/repo/pull/253)
- [ ] Verify webhook retries — in progress · cody · 14:55 <!-- #verif-1037 1760540131 -->
- [ ] Retry retry backoff — blocked · me · PROD · 14:57 <!-- #retry-1074 1760540262 cmd -->
  ```sh
  php artisan queue:retry 8812
  ```
- [ ] Review queue job 8812 — todo · 14:59 <!-- #revie-1111 1760540393 -->
- [ ] Draft search index — in progress · claudia · 15:02 <!-- #draft-1148 1760540524 -->
  Only happens after midnight UTC
- [ ] Close feature flag drift — in progress · redd · LOCAL · 15:04 <!-- #close-1185 1760540655 -->
  Links: CORE-2841 · Sentry PORTAL-1F2
- [ ] Reproduce staging deploy — blocked · 15:06 <!-- #repro-1222 1760540786 -->
- [ ] Triage nightly import — todo · cody · 15:08 <!-- #triag-1259 1760540917 -->
- [ ] Document tenant migration — in progress · me · 15:10 <!-- #docum-1296 1760541048 -->
  Waiting for the vendor to reply
- [ ] Backfill login timeout — in progress · 15:12 <!-- #backf-1333 1760541179 -->

## Next
- [ ] Rotate user avatar sync — todo · claudia · 15:15 <!-- #rotat-1370 1760541310 -->
  Links: Sentry PORTAL-1F2 · run 9912 · index.md:42
- [ ] Audit slow query 77 — todo · redd · 15:17 <!-- #audit-1407 1760541441 -->
- [ ] Check report export — todo · 15:19 <!-- #check-1444 1760541572 -->
  Seen on host 14, see the log for detail
- [ ] Verify email digest — todo · cody · CANADA · 15:21 <!-- #verif-1481 1760541703 cmd -->
  ```sh
  kubectl rollout restart deploy/web
  ```
- [ ] Retry health probe — todo · me · 15:23 <!-- #retry-1518 1760541834 -->
- [ ] Review invoice batch — todo · 15:26 <!-- #revie-1555 1760541965 -->
  Links: run 9912
- [ ] Draft audit trail gap — todo · claudia · 15:28 <!-- #draft-1592 1760542096 -->
  Only happens after midnight UTC
- [ ] Close config reload — todo · redd · PROD · 15:30 <!-- #close-1629 1760542227 -->
- [ ] Reproduce cache warmup — todo · 15:32 <!-- #repro-1666 1760542358 -->
- [ ] Triage pdf renderer — todo · cody · 15:34 <!-- #triag-1703 1760542489 -->
Note to self: everything under Next is unprioritised.

## Waiting on you
- [ ] Document referral 4411 duplicate — needs you · me · 15:37 <!-- #docum-1740 1760542620 -->
  Waiting for the vendor to reply
  Links: index.md:42 · [PR #253](https://github.com/example/repo/pull/253)
- [ ] Backfill webhook retries — needs you · 15:39 <!-- #backf-1777 1760542751 -->
- [ ] Rotate retry backoff — needs you · claudia · 15:41 <!-- #rotat-1814 1760542882 -->
- [ ] Audit queue job 8812 — needs you · redd · 15:43 <!-- #audit-1851 1760543013 -->
- [ ] Check search index — needs you · DEMO · 15:45 <!-- #check-1888 1760543144 cmd -->
  ```sh
  ./scripts/reindex.sh --dry-run
  ```
  Seen on host 14, see the log for detail
- [ ] Verify feature flag drift — needs you · cody · 15:47 <!-- #verif-1925 1760543275 -->
  Links: [PR #253](https://github.com/example/repo/pull/253) · CORE-2841 · Sentry PORTAL-1F2
- [ ] Retry staging deploy — needs you · me · 15:50 <!-- #retry-1962 1760543406 -->
- [ ] Review nightly import — needs you · 15:52 <!-- #revie-1999 1760543537 -->
- [ ] Draft tenant migration — needs you · claudia · 15:54 <!-- #draft-2036 1760543668 -->
  Only happens after midnight UTC
- [ ] Close login timeout — needs you · redd · 15:56 <!-- #close-2073 1760543799 -->

## Done
- [x] Reproduce user avatar sync — done · 15:58 <!-- #repro-2110 1760543930 -->
  Links: CORE-2841
- [x] Triage slow query 77 — done · cody · 16:01 <!-- #triag-2147 1760544061 -->
- [x] Document report export — done · me · 16:03 <!-- #docum-2184 1760544192 -->
  Waiting for the vendor to reply
- [x] Backfill email digest — done · 16:05 <!-- #backf-2221 1760544323 -->
- [x] Rotate health probe — done · claudia · 16:07 <!-- #rotat-2258 1760544454 -->
- [x] Audit invoice batch — done · redd · STAGING · 16:09 <!-- #audit-2295 1760544585 cmd -->
  ```sh
  make seed
  ```
  Links: Sentry PORTAL-1F2 · run 9912
- [x] Check audit trail gap — done · 16:11 <!-- #check-2332 1760544716 -->
  Seen on host 14, see the log for detail
- [x] Verify config reload — done · cody · 16:14 <!-- #verif-2369 1760544847 -->
- [x] Retry cache warmup — done · me · 16:16 <!-- #retry-2406 1760544978 -->
- [x] Review pdf renderer — done · 16:18 <!-- #revie-2443 1760545109 -->
- [x] Draft referral 4411 duplicate — done · claudia · 16:20 <!-- #draft-2480 1760545240 -->
  Only happens after midnight UTC
  Links: run 9912 · index.md:42 · [PR #253](https://github.com/example/repo/pull/253)
- [x] Close webhook retries — done · redd · 16:22 <!-- #close-2517 1760545371 -->

## Findings
- [ ] Reproduce retry backoff — todo · 16:25 <!-- #repro-2554 1760545502 -->
- [x] Triage queue job 8812 — done · cody · 16:27 <!-- #triag-2591 1760545633 -->
- [ ] Document search index — todo · me · 16:29 <!-- #docum-2628 1760545764 -->
  Waiting for the vendor to reply
- [x] Backfill feature flag drift — done · 16:31 <!-- #backf-2665 1760545895 -->
  Links: index.md:42
- [ ] Rotate staging deploy — todo · claudia · ENV? · 16:33 <!-- #rotat-2702 1760546026 cmd -->
  ```sh
  cargo test -p core
  ```
- [x] Audit nightly import — done · redd · 16:35 <!-- #audit-2739 1760546157 -->
- [ ] Check tenant migration — todo · 16:38 <!-- #check-2776 1760546288 -->
  Seen on host 14, see the log for detail
- [x] Verify login timeout — done · cody · 16:40 <!-- #verif-2813 1760546419 -->
- [ ] Retry user avatar sync — todo · me · 16:42 <!-- #retry-2850 1760546550 -->
  Links: [PR #253](https://github.com/example/repo/pull/253) · CORE-2841
- [x] Review slow query 77 — done · 16:44 <!-- #revie-2887 1760546681 -->

## Loose ends
Anything here has no owner yet and may be dropped.

- [ ] Draft report export — todo · claudia · 16:46 <!-- #draft-2924 1760546812 -->
  Only happens after midnight UTC
- [ ] Close email digest — todo · redd · 16:49 <!-- #close-2961 1760546943 -->
- [ ] Reproduce health probe — todo · 16:51 <!-- #repro-2998 1760547074 -->
- [ ] Triage invoice batch — todo · cody · 16:53 <!-- #triag-3035 1760547205 -->
  Links: CORE-2841 · Sentry PORTAL-1F2 · run 9912
- [ ] Document audit trail gap — todo · me · 16:55 <!-- #docum-3072 1760547336 -->
  Waiting for the vendor to reply
- [ ] Backfill config reload — todo · 16:57 <!-- #backf-3109 1760547467 -->
- [ ] Rotate cache warmup — todo · claudia · 16:59 <!-- #rotat-3146 1760547598 -->
- [ ] Audit pdf renderer — todo · redd · 17:02 <!-- #audit-3183 1760547729 -->

## Log
- 09:01 Claudia: logged event 01
- 09:02 Claudia: logged event 02
- 09:03 Claudia: logged event 03
- 09:04 Claudia: logged event 04
- 09:05 Claudia: logged event 05
- 09:06 Claudia: logged event 06
- 09:07 Claudia: logged event 07
- 09:08 Claudia: logged event 08
- 09:09 Claudia: logged event 09
- 09:10 Claudia: logged event 10
- 09:11 Claudia: logged event 11
- 09:12 Claudia: logged event 12
