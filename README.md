# hmac-webhook-receiver

Inbound webhooks for Salesforce, done the way the senders' own docs ask for and most Apex endpoints skip: HMAC-SHA256 signature verification with a timestamp window and a constant-time compare, replay and redelivery protection through a unique event id, secret rotation without a window of rejected deliveries, handlers configured in metadata and run in or out of the request, a Reprocess button, an alert event, and a record of every delivery, including the ones that were rejected.

`POST /services/apexrest/webhooks/v1/<source>`

## Why an org needs it

Every SaaS tool the business buys wants to push events into Salesforce: payments settled, documents signed, tickets closed, contacts unsubscribed. The usual Apex REST endpoint parses the body and updates a record, and that is all. Nobody checks the signature, so anyone who finds the URL can create records; redeliveries (every sender retries) create duplicates; a handler that throws returns a 500, the sender retries, and the duplicates multiply; the integration user's secret has never been rotated because rotating it would drop deliveries; and when something goes wrong there is no record of what arrived. Each new sender gets a new endpoint and the same gaps.

## What your org gets

- **Only the real sender gets in.** Each delivery is verified with HMAC-SHA256 over the body, or over `"<timestamp>.<body>"` with a tolerance window so a captured request cannot be replayed later. The compare is constant-time. A forged delivery gets a 401 and leaves a Rejected record with the reason and headers, never the payload.
- **Redeliveries are harmless.** Each event is stored under `source:eventId` with a unique index, so a redelivered event gets a 200 and is not processed twice, even when two deliveries race.
- **Secrets rotate with no downtime.** Move the old secret to **Previous Secret**, enter the new one, update the sender when convenient. Deliveries signed with either are accepted; the ones still using the old secret show up in the **On Previous Secret** list view, so you know when to clear it.
- **A new sender is configuration plus a short class.** `Webhook_Source__mdt` says which headers carry the signature, timestamp, event id, and type; `Webhook_Handler__mdt` maps an event type to an Apex class implementing one method. Handlers run after the sender has its 200, so a slow handler cannot cause a redelivery storm.
- **Every delivery is a record.** The **Webhook Events** tab ships with **Needs Attention** (Failed), **Rejected Deliveries**, **On Previous Secret**, and **Recent Events** list views, with payload, headers, handler, timings, and errors on the record.
- **A Reprocess button.** After a handler fix, **Reprocess** on the event re-runs it now; the same **Reprocess webhook events** action is available to any Flow. Ignored events get picked up the same way once a handler is registered.
- **Alerts where you already have them.** A `Webhook_Alert__e` platform event is published for every rejected delivery, failed handler, and aborted processor. A platform-event-triggered flow posts to a channel, opens a case, or pages the on-call. A burst of rejections is how you find out someone is probing the endpoint or the sender rotated its secret.
- **Housekeeping.** A daily purge deletes Processed, Ignored, and Rejected events past their source's retention (30 days by default); Failed events are kept until someone looks.
- **Failures are kept, not lost.** A handler that throws marks the event Failed with the message and stack trace. A Finalizer on the queueable catches the one case a try/catch cannot (a limit exception), so no event stays Received forever.

## What happens to a delivery

```
request ─► resolve source (Webhook_Source__mdt, 404 if unknown or inactive)
        ─► verify HMAC-SHA256 over the body, or over "<timestamp>.<body>" with a tolerance window,
           against the current secret, then the previous one
              invalid ─► Webhook_Event__c (Rejected, reason, no payload), Webhook_Alert__e, and 401
        ─► read the event id and type from headers or JSON paths (400 without an id)
        ─► insert Webhook_Event__c (Signed With: Current or Previous); External Event Id is unique
              collision ─► 200 { duplicate: true } and nothing else happens
        ─► find the handler (exact event type, then the source's "*")
              none    ─► Ignored
              async   ─► 200 { status: "Received" }, WebhookProcessor queueable runs the handler
              sync    ─► handler runs in the request, 200 { status: "Processed" | "Failed" }
        handler throws ─► Failed + Webhook_Alert__e; Reprocess re-runs it after the fix
WebhookEventPurge (daily, 02:30) ─► deletes settled events past the source's Retention Days
```

- **Two signing schemes** cover most senders: the raw body with a prefixed digest (GitHub `X-Hub-Signature-256: sha256=…`, Shopify, many SaaS tools) and `"<unix seconds>.<body>"` with a separate timestamp header (Stripe and the tools that copied it). The timestamp bounds replays: five minutes by default, per source.
- **Rejections are logged without the payload.** A forged body is never stored; the source, the reason (`signature mismatch`, `timestamp outside tolerance (612s)`), and the interesting headers are, with the signature truncated.
- **Handlers live in metadata.** `Webhook_Handler__mdt` maps a source and event type to an Apex class implementing `WebhookHandler`, with `*` as the per-source fallback. Async (default) answers the sender immediately and runs the handler in a queueable. Sync is for handlers that must complete before the sender moves on.
- **Secrets stay out of version control.** They live in the protected `Webhook_Secret__c` custom setting, entered in Setup, keyed by source name, with a Previous Secret field for rotations.

## Configure a source

| `Webhook_Source__mdt` field | Meaning | GitHub example | Stripe-style example |
|---|---|---|---|
| Developer Name | URL segment: `/webhooks/v1/<name>` | `Github` | `Demo` |
| Signature Header | Header with the HMAC hex digest | `X-Hub-Signature-256` | `X-Signature` |
| Signature Prefix | Text before the digest | `sha256=` | |
| Scheme | What is signed | Body only | Timestamp "." body |
| Timestamp Header | Unix seconds the sender signed | | `X-Timestamp` |
| Tolerance (seconds) | Allowed clock skew; default 300 | | `300` |
| Event Id Header / Path | Where the unique delivery id is | `X-GitHub-Delivery` | path `id` |
| Event Type Header / Path | Where the event type is | `X-GitHub-Event` | path `type` |
| Retention Days | Settled events are deleted after this; default 30 | | `30` |

Then add a `Webhook_Secret__c` record named after the source with the shared secret, and one or more `Webhook_Handler__mdt` rows.

## Write a handler

```apex
public with sharing class OrderPaidHandler implements WebhookHandler {
    public void handle(Webhook_Event__c event, Map<String, Object> payload) {
        String orderNumber = JsonPath.getString(payload, 'data.object.metadata.order');
        List<Order__c> orders = [SELECT Id FROM Order__c WHERE Order_Number__c = :orderNumber LIMIT 1];
        if (orders.isEmpty()) {
            throw new WebhookDispatcher.HandlerException('no order ' + orderNumber); // event goes to Failed with this reason
        }
        update new Order__c(Id = orders[0].Id, Paid_At__c = System.now(), Payment_Event__c = event.External_Event_Id__c);
    }
}
```

`JsonPath` reads dot paths (`data.object.id`, `items.0.sku`) out of the parsed body. Handlers need a public no-argument constructor; the dispatcher creates them with `Type.forName`. Write them so a second run is safe: Reprocess may run them again.

## Install and try it

```bash
sf project deploy start --target-org <org>
sf org assign permset --name Webhook_Receiver --target-org <org>
sf apex run --target-org <org> --file scripts/apex/schedule-jobs.apex          # once per org: the daily purge
# Setup > Custom Settings > Webhook Secret > Manage > New: Name "Demo", Secret "<your secret>"
scripts/send-demo.sh <org> "<your secret>" someone@example.com    # signs and posts a contact.unsubscribed event
sf data query --target-org <org> --file scripts/soql/recent-events.soql
```

The sample handler (`ContactUnsubscribeHandler`, registered for `Demo` / `contact.unsubscribed`) opts every Contact with the payload's email out of email. Point a real sender at `https://<my domain>/services/apexrest/webhooks/v1/<source>` with an integration user's OAuth token; the HMAC check is on top of Salesforce authentication, not instead of it.

## Operate it

| Status | Meaning | What Reprocess does |
|---|---|---|
| Received | Verified and stored; handler queued | Runs the handler now (for an event the processor never reached) |
| Processed | Handler finished | Nothing |
| Failed | Handler threw (or the processor died); `Error Message` has the reason | Runs the handler again |
| Ignored | No active handler for the source and type | Runs the handler now that one exists |
| Rejected | Signature or timestamp check failed; no payload stored | Nothing; the sender has to send it again |

- **Rotating a secret:** on the source's `Webhook_Secret__c` record, copy **Secret** into **Previous Secret**, paste the new secret into **Secret**, then update the sender. Watch **On Previous Secret**; when it stops filling, clear **Previous Secret**. No delivery is rejected at any point.
- **Alerting:** build a platform-event-triggered flow on `Webhook_Alert__e` (kind, source, event type, external id, event record id, reason). Route `Rejected` to security and `Handler Failed` to the integration owner; throttle in the flow if a sender is noisy.
- **Pausing a sender:** uncheck **Active** on its source; deliveries get a 404 until it is back, and the sender's own retry queue holds them.

## Limits and trade-offs

- **Authentication first.** Apex REST needs a session, so senders call with an integration user's OAuth token (client credentials flow) and the HMAC proves the body came from them. For senders that cannot add an Authorization header, front the endpoint with a Site and a guest-user profile that holds only this class, and lean on the HMAC and timestamp.
- **Payloads are stored as text** up to 128 KB; larger bodies are truncated on the record (the handler still gets the full body in sync mode, not in async mode).
- **One handler per source and type.** Fan-out belongs in the handler or in a platform event it publishes.
- **Sync handlers share the sender's timeout.** Most senders give you 10 to 30 seconds; keep sync handlers to a query and an update.
- **An alert per rejection** is right for a quiet endpoint and noisy for a probed one; the subscribing flow is the place to throttle.
- The companion project `integration-log-retry` covers the outbound direction.

## Development

```bash
scripts/validate.sh <org alias>                       # deploy and run all local tests with coverage
pmd check -d force-app -R pmd/ruleset.xml -f text     # static analysis, same ruleset as CI
```

Validated in a Developer Edition org on API 68.0: 41 tests, 96–100% coverage per class, and a live secret rotation through `scripts/send-demo.sh`: with the old secret moved to Previous Secret, a delivery signed with it was accepted and flagged `Previous`, one signed with the new secret came through as `Current`, and one signed with a wrong secret was rejected with `signature mismatch`.

Tests drive the real REST shell through `RestContext` with the shipped GitHub and Demo source metadata, sign requests with the same `hmacHex` the receiver uses, and cover tampering, replays, redelivery, rotation, missing ids, unknown sources, sync and async handlers, handler failures, re-processing, alerts, the purge, and the finalizer.

## License

MIT
