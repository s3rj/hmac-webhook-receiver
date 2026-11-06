# hmac-webhook-receiver

Inbound webhooks for Salesforce, done the way the senders' own docs ask for and most Apex endpoints skip: HMAC-SHA256 signature verification with a timestamp window and a constant-time compare, replay and redelivery protection through a unique event id, handlers configured in metadata and run in or out of the request, and a record of every delivery, including the ones that were rejected.

`POST /services/apexrest/webhooks/v1/<source>`

## What happens to a delivery

```
request ─► resolve source (Webhook_Source__mdt, 404 if unknown or inactive)
        ─► verify HMAC-SHA256 over the body, or over "<timestamp>.<body>" with a tolerance window
              invalid ─► Webhook_Event__c (Rejected, reason, no payload) and 401
        ─► read the event id and type from headers or JSON paths (400 without an id)
        ─► insert Webhook_Event__c; External Event Id is unique
              collision ─► 200 { duplicate: true } and nothing else happens
        ─► find the handler (exact event type, then the source's "*")
              none    ─► Ignored
              async   ─► 200 { status: "Received" }, WebhookProcessor queueable runs the handler
              sync    ─► handler runs in the request, 200 { status: "Processed" | "Failed" }
```

- **Two signing schemes** cover most senders: the raw body with a prefixed digest (GitHub `X-Hub-Signature-256: sha256=…`, Shopify, many SaaS tools) and `"<unix seconds>.<body>"` with a separate timestamp header (Stripe and the tools that copied it). The timestamp bounds replays: five minutes by default, per source.
- **Constant-time comparison.** The digest check does not stop at the first differing byte, so response time leaks nothing about how close a forged signature was.
- **Rejections are logged without the payload.** A forged body is never stored; the source, the reason (`signature mismatch`, `timestamp outside tolerance (612s)`), and the interesting headers are, with the signature truncated.
- **Redeliveries are harmless.** Senders retry on timeouts and 5xx responses. Each event is stored under `source:eventId` with a unique index, so a redelivered event gets a 200 and is not processed twice, even when two deliveries race.
- **Handlers live in metadata.** `Webhook_Handler__mdt` maps a source and event type to an Apex class implementing `WebhookHandler`, with `*` as the per-source fallback. Async (default) answers the sender immediately and runs the handler in a queueable, so a slow or failing handler cannot cause a redelivery storm. Sync is for handlers that must complete before the sender moves on.
- **Failures are kept, not lost.** A handler that throws marks the event `Failed` with the message and stack trace; `WebhookDispatcher.reprocess(ids)` re-runs it after the fix. A Finalizer on the queueable catches the one case a try/catch cannot (a limit exception), so no event stays `Received` forever.
- **Secrets stay out of version control.** They live in the protected `Webhook_Secret__c` custom setting, entered in Setup, keyed by source name.

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

`JsonPath` reads dot paths (`data.object.id`, `items.0.sku`) out of the parsed body. Handlers need a public no-argument constructor; the dispatcher creates them with `Type.forName`.

## Install and try it

```bash
sf project deploy start --target-org <org>
sf org assign permset --name Webhook_Receiver --target-org <org>
# Setup > Custom Settings > Webhook Secret > Manage > New: Name "Demo", Secret "<your secret>"
scripts/send-demo.sh <org> "<your secret>" someone@example.com    # signs and posts a contact.unsubscribed event
sf data query --target-org <org> --file scripts/soql/recent-events.soql
```

The sample handler (`ContactUnsubscribeHandler`, registered for `Demo` / `contact.unsubscribed`) opts every Contact with the payload's email out of email. Point a real sender at `https://<my domain>/services/apexrest/webhooks/v1/<source>` with an integration user's OAuth token; the HMAC check is on top of Salesforce authentication, not instead of it.

## Event statuses

| Status | Meaning |
|---|---|
| Received | Verified and stored; handler queued |
| Processed | Handler finished |
| Failed | Handler threw (or the processor died); `Error Message` has the reason; re-run with `WebhookDispatcher.reprocess()` |
| Ignored | No active handler for the source and type |
| Rejected | Signature or timestamp check failed; no payload stored |

## Limits and trade-offs

- **Authentication first.** Apex REST needs a session, so senders call with an integration user's OAuth token (client credentials flow) and the HMAC proves the body came from them. For senders that cannot add an Authorization header, front the endpoint with a Site and a guest-user profile that holds only this class, and lean on the HMAC and timestamp.
- **Payloads are stored as text** up to 128 KB; larger bodies are truncated on the record (the handler still gets the full body in sync mode, not in async mode).
- **One handler per source and type.** Fan-out belongs in the handler or in a platform event it publishes.
- **Sync handlers share the sender's timeout.** Most senders give you 10 to 30 seconds; keep sync handlers to a query and an update.
- The companion project `integration-log-retry` covers the outbound direction.

## Development

```bash
scripts/validate.sh <org alias>                       # deploy and run all local tests with coverage
pmd check -d force-app -R pmd/ruleset.xml -f text     # static analysis, same ruleset as CI
```

Validated in a Developer Edition org on API 68.0: 32 tests, 94–100% coverage per class, and a live signed delivery through `scripts/send-demo.sh` that came back `{"received":true,"duplicate":false,"status":"Received"}`, was processed by the queueable, and opted the matching Contact out of email.

Tests drive the real REST shell through `RestContext` with the shipped GitHub and Demo source metadata, sign requests with the same `hmacHex` the receiver uses, and cover tampering, replays, redelivery, missing ids, unknown sources, sync and async handlers, handler failures, re-processing, and the finalizer.

## License

MIT
