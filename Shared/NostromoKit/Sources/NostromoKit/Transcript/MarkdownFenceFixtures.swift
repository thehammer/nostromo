import Foundation

/// Test data. Lives in Sources, not Tests, so the Mac test bundle can use it as
/// well as the Kit tests (the same precedent as `BenchmarkTranscript`).
public enum MarkdownFenceFixtures {

    /// The message from the 2026-10-14 bug report, byte for byte (ASCII, no tabs,
    /// no CR, no trailing whitespace, no trailing newline) except for two values
    /// redacted to the same length so wrapping and heights are unchanged: the AWS
    /// account id and the ECS task id.
    ///
    /// It exercises fences with no blank line before them, a bare fence, `php` and
    /// `sql` info strings, underscores and `\\` inside code, and inline code and
    /// bold in the surrounding prose.
    public static let reportedMessage: String = #"""
Both alerts are resolved: `PORTAL_DEV-1Q0` and `PORTAL_DEV-1Q1`. The connection command is staged on your clipboard. I haven't run it, and I haven't sent anything to a production shell.

**Staged command** (admin-portal, production, portal service, tinker)
```
aws ecs execute-command --profile production-developers --region us-east-2 --cluster carefeed-prod-ecs --task arn:aws:ecs:us-east-2:000000000000:task/carefeed-prod-ecs/00000000000000000000000000000000 --container main --interactive --command "php artisan tinker"
```
The task ARN was picked when I generated the command. If it has been replaced by the time you paste it, regenerate it.

**Reprocess commands for referral 14464** (from #5274's body; paste these once you're in tinker)
```php
$referral = \App\Modules\Referrals\Models\Referral::findOrFail(14464);
$result = app(\App\Modules\Referrals\Services\ReprocessReferralPipelineService::class)->reprocess($referral);
$result->documentCount;
```
- **This is the service behind the UI's "reprocess" action.** It throws if an assessment is already in flight, so an exception there is a guard, not a failure.
- **The migration has applied**, so the precondition in the PR is met.
- **The follow-up commit** in #5274 also fixed `EvaluateReferralIndicationsJob`, which failed on 14464 too. Both fixes are in the deployed release, so it shouldn't hit 1038 at Evaluate this time.

**Verify afterward** (I can run it read-only from here): failed runs for the referral since reprocessing, and any new 1038 events.
```sql
SELECT REPLACE(job_class,'App\\Modules\\Referrals\\Jobs\\','') job, status, outcome_quality, LEFT(COALESCE(error_message,'-'),60) err, COALESCE(completed_at,updated_at) at FROM pipeline_job_runs WHERE referral_id = 14464 ORDER BY id DESC LIMIT 20
```
Tell me when you've run it and I'll check the result.
"""#

    /// One fenced block per supported language (plus a `text` fence and a fence
    /// with no info string), each short and containing at least one keyword, so
    /// the Mac tests can check that every language colours something and that
    /// plain fences stay plain. The first block is Swift: `let answer = 42`.
    public static let highlightedMessage: String = #"""
Highlighting sample.
```swift
let answer = 42
struct Point { var x: Int } // origin
```
```sql
SELECT id, name FROM users WHERE active = TRUE -- active only
```
```php
<?php
$referral = Referral::find(14464);
```
```bash
if [ -n "$HOME" ]; then echo "$HOME"; fi # home
```
```json
{"name": "nostromo", "count": 3, "ok": true}
```
```yaml
name: nostromo # app
items:
  - one
```
```rust
fn main() { let s: &'static str = "hi"; }
```
```python
def f(x):
    return None if x else "y"
```
```js
const x = `a ${b}`; // note
```
```diff
@@ -1,2 +1,2 @@
-old
+new
```
```text
let answer = 42
```
```
let answer = 42
```
Done.
"""#
}
