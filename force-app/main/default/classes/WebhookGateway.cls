/**
 * The receive pipeline, independent of RestContext so it can be tested without it:
 * resolve source -> verify signature (and timestamp) -> extract id and type -> store (dedupe) -> dispatch.
 */
public without sharing class WebhookGateway {
    public class Response {
        public Integer statusCode { get; private set; }
        public Map<String, Object> body { get; private set; }

        public Response(Integer statusCode, Map<String, Object> body) {
            this.statusCode = statusCode;
            this.body = body;
        }
    }

    public class Delivery {
        public String sourceName;
        public Blob body;
        public Map<String, String> headers = new Map<String, String>();

        /** Case-insensitive header lookup. */
        public String header(String name) {
            if (name == null) {
                return null;
            }
            for (String key : headers.keySet()) {
                if (key.equalsIgnoreCase(name)) {
                    return headers.get(key);
                }
            }
            return null;
        }
    }

    @TestVisible
    private static Datetime now = null;

    public static Response receive(Delivery delivery) {
        WebhookSources.Source source = WebhookSources.find(delivery.sourceName);
        if (source == null) {
            return new Response(404, new Map<String, Object>{ 'error' => 'unknown source' });
        }
        Map<String, String> kept = keptHeaders(delivery, source);
        WebhookSignature.Verdict verdict = WebhookSignature.verify(
            delivery.body,
            delivery.header(source.signatureHeader),
            source.signaturePrefix,
            WebhookSources.secretFor(source.name),
            source.scheme,
            delivery.header(source.timestampHeader),
            source.toleranceSeconds,
            now == null ? System.now() : now
        );
        if (!verdict.valid) {
            WebhookEvents.rejected(source.name, verdict.reason, kept);
            return new Response(401, new Map<String, Object>{ 'error' => 'invalid signature' });
        }

        String payload = delivery.body == null ? '' : delivery.body.toString();
        Object parsed = parseLeniently(payload);
        String eventId = firstNonBlank(delivery.header(source.eventIdHeader), JsonPath.getString(parsed, source.eventIdPath));
        if (String.isBlank(eventId)) {
            return new Response(400, new Map<String, Object>{ 'error' => 'missing event id' });
        }
        String eventType = firstNonBlank(delivery.header(source.eventTypeHeader), JsonPath.getString(parsed, source.eventTypePath));

        Webhook_Event__c event = new Webhook_Event__c(
            Source__c = source.name,
            Event_Type__c = WebhookEvents.clip(eventType, 255),
            External_Event_Id__c = WebhookEvents.clip(source.name + ':' + eventId, 255),
            Status__c = WebhookEvents.STATUS_RECEIVED,
            Received_At__c = System.now(),
            Payload__c = WebhookEvents.clip(payload, WebhookEvents.PAYLOAD_MAX),
            Headers__c = WebhookEvents.clip(JSON.serializePretty(kept), WebhookEvents.ERROR_MAX),
            Attempts__c = 0
        );
        WebhookEvents.StoreResult stored = WebhookEvents.store(event);
        if (stored.duplicate) {
            return new Response(200, new Map<String, Object>{ 'received' => true, 'duplicate' => true, 'eventId' => eventId });
        }
        String status = WebhookDispatcher.dispatch(stored.event);
        return new Response(200, new Map<String, Object>{ 'received' => true, 'duplicate' => false, 'eventId' => eventId, 'status' => status });
    }

    private static Map<String, String> keptHeaders(Delivery delivery, WebhookSources.Source source) {
        Map<String, String> kept = new Map<String, String>();
        for (String name : source.interestingHeaders()) {
            String value = delivery.header(name);
            if (value != null) {
                kept.put(name, name.equalsIgnoreCase(source.signatureHeader) ? value.abbreviate(16) : value); // never store a full signature
            }
        }
        return kept;
    }

    private static Object parseLeniently(String payload) {
        if (String.isBlank(payload)) {
            return null;
        }
        try {
            return JSON.deserializeUntyped(payload);
        } catch (JSONException e) {
            return null;
        }
    }

    private static String firstNonBlank(String a, String b) {
        return String.isNotBlank(a) ? a : b;
    }
}
