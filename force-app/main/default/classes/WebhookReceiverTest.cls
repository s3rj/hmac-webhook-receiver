/**
 * End-to-end through the REST shell with the shipped Webhook Source metadata (GitHub and Demo).
 */
@IsTest
private class WebhookReceiverTest {
    private static final String SECRET = 'whsec_test_secret';

    private static void setup() {
        WebhookSources.secretOverrides = new Map<String, String>{ 'demo' => SECRET, 'github' => SECRET };
        WebhookDispatcher.handlerOverrides = new Map<String, WebhookDispatcher.HandlerConfig>{
            'demo|contact.unsubscribed' => new WebhookDispatcher.HandlerConfig('RecordingWebhookHandler', false),
            'github|push' => new WebhookDispatcher.HandlerConfig('RecordingWebhookHandler', false)
        };
    }

    private static Map<String, Object> post(String source, String body, Map<String, String> headers) {
        RestRequest request = new RestRequest();
        request.requestURI = '/webhooks/v1/' + source;
        request.httpMethod = 'POST';
        request.requestBody = body == null ? null : Blob.valueOf(body);
        for (String name : headers.keySet()) {
            request.addHeader(name, headers.get(name));
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();

        WebhookReceiver.receive();

        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        result.put('statusCode', RestContext.response.statusCode);
        return result;
    }

    private static Map<String, String> githubHeaders(String body, String deliveryId, String eventType) {
        return new Map<String, String>{
            'X-Hub-Signature-256' => 'sha256=' + WebhookSignature.hmacHex(body, SECRET),
            'X-GitHub-Delivery' => deliveryId,
            'X-GitHub-Event' => eventType,
            'Content-Type' => 'application/json'
        };
    }

    private static Map<String, String> demoHeaders(String body, Datetime sentAt) {
        String ts = String.valueOf(sentAt.getTime() / 1000);
        return new Map<String, String>{ 'X-Timestamp' => ts, 'X-Signature' => WebhookSignature.hmacHex(ts + '.' + body, SECRET) };
    }

    @IsTest
    static void githubStyleDeliveryIsVerifiedStoredAndProcessed() {
        setup();
        String body = '{"ref":"refs/heads/main","repository":{"full_name":"s3rj/example"}}';

        Map<String, Object> result = post('github', body, githubHeaders(body, 'delivery-1', 'push'));

        Assert.areEqual(200, result.get('statusCode'), 'accepted');
        Assert.areEqual(true, result.get('received'), 'received');
        Assert.areEqual(false, result.get('duplicate'), 'first delivery');
        Assert.areEqual('delivery-1', result.get('eventId'), 'event id echoed');
        Assert.areEqual('Processed', result.get('status'), 'sync handler ran');
        Webhook_Event__c event = [SELECT Source__c, Event_Type__c, External_Event_Id__c, Status__c, Payload__c, Headers__c FROM Webhook_Event__c WHERE External_Event_Id__c = 'Github:delivery-1'];
        Assert.areEqual('Github', event.Source__c, 'source from the URL');
        Assert.areEqual('push', event.Event_Type__c, 'type from the header');
        Assert.areEqual(body, event.Payload__c, 'payload stored verbatim');
        Assert.isTrue(event.Headers__c.contains('X-GitHub-Delivery'), 'interesting headers kept');
        Assert.isFalse(event.Headers__c.contains(WebhookSignature.hmacHex(body, SECRET)), 'full signature never stored');
        Assert.areEqual(new List<String>{ 'push' }, RecordingWebhookHandler.types, 'handler received the type');
    }

    @IsTest
    static void timestampStyleDeliveryReadsIdAndTypeFromTheBody() {
        setup();
        String body = '{"id":"evt_1","type":"contact.unsubscribed","email":"someone@example.com"}';

        Map<String, Object> result = post('demo', body, demoHeaders(body, System.now()));

        Assert.areEqual(200, result.get('statusCode'), 'accepted');
        Assert.areEqual('evt_1', result.get('eventId'), 'id from the JSON path');
        Webhook_Event__c event = [SELECT Event_Type__c, Status__c FROM Webhook_Event__c WHERE External_Event_Id__c = 'Demo:evt_1'];
        Assert.areEqual('contact.unsubscribed', event.Event_Type__c, 'type from the JSON path');
        Assert.areEqual('Processed', event.Status__c, 'processed');
    }

    @IsTest
    static void redeliveryIsAcknowledgedButNotProcessedTwice() {
        setup();
        String body = '{"id":"evt_2","type":"contact.unsubscribed","email":"someone@example.com"}';

        Map<String, Object> first = post('demo', body, demoHeaders(body, System.now()));
        Map<String, Object> second = post('demo', body, demoHeaders(body, System.now()));

        Assert.areEqual(false, first.get('duplicate'), 'first time');
        Assert.areEqual(200, second.get('statusCode'), 'redelivery still gets a 200 so the sender stops');
        Assert.areEqual(true, second.get('duplicate'), 'flagged as a duplicate');
        Assert.areEqual(1, [SELECT COUNT() FROM Webhook_Event__c WHERE External_Event_Id__c = 'Demo:evt_2'], 'one record');
        Assert.areEqual(1, RecordingWebhookHandler.handled.size(), 'handled once');
    }

    @IsTest
    static void badSignatureIsRejectedAndLoggedWithoutThePayload() {
        setup();
        String body = '{"id":"evt_3","type":"contact.unsubscribed","email":"someone@example.com"}';
        Map<String, String> headers = demoHeaders(body, System.now());
        headers.put('X-Signature', WebhookSignature.hmacHex('tampered', SECRET));

        Map<String, Object> result = post('demo', body, headers);

        Assert.areEqual(401, result.get('statusCode'), 'rejected');
        Assert.areEqual('invalid signature', result.get('error'), 'no detail leaks to the sender');
        Webhook_Event__c rejected = [SELECT Status__c, Payload__c, Error_Message__c, Source__c FROM Webhook_Event__c WHERE Status__c = 'Rejected' LIMIT 1];
        Assert.areEqual('Demo', rejected.Source__c, 'source recorded');
        Assert.isNull(rejected.Payload__c, 'forged payload not stored');
        Assert.areEqual('signature mismatch', rejected.Error_Message__c, 'reason for the admin');
        Assert.isTrue(RecordingWebhookHandler.handled.isEmpty(), 'nothing processed');
    }

    @IsTest
    static void staleTimestampIsRejected() {
        setup();
        String body = '{"id":"evt_4","type":"contact.unsubscribed"}';

        Map<String, Object> result = post('demo', body, demoHeaders(body, System.now().addMinutes(-10)));

        Assert.areEqual(401, result.get('statusCode'), 'rejected');
        Assert.isTrue([SELECT Error_Message__c FROM Webhook_Event__c WHERE Status__c = 'Rejected' LIMIT 1].Error_Message__c.startsWith('timestamp outside tolerance'), 'reason');
    }

    @IsTest
    static void unknownAndInactiveSourcesAnswer404() {
        setup();
        Assert.areEqual(404, post('nope', '{}', new Map<String, String>()).get('statusCode'), 'unknown source');

        WebhookSources.sourceOverrides = new Map<String, WebhookSources.Source>{ 'off' => new WebhookSources.Source('Off').withActive(false) };
        Assert.areEqual(404, post('off', '{}', new Map<String, String>()).get('statusCode'), 'inactive source');
        Assert.areEqual(0, [SELECT COUNT() FROM Webhook_Event__c WHERE Received_At__c = TODAY], 'nothing stored');
    }

    @IsTest
    static void deliveryWithoutAnEventIdIs400() {
        setup();
        String body = '{"type":"contact.unsubscribed"}';

        Map<String, Object> result = post('demo', body, demoHeaders(body, System.now()));

        Assert.areEqual(400, result.get('statusCode'), 'bad request');
        Assert.areEqual('missing event id', result.get('error'), 'reason');
    }

    @IsTest
    static void nonJsonBodyWithHeaderIdsIsStillAccepted() {
        setup();
        String body = 'plain text payload';

        Map<String, Object> result = post('github', body, githubHeaders(body, 'delivery-2', 'push'));

        Assert.areEqual(200, result.get('statusCode'), 'accepted');
        Assert.isTrue(RecordingWebhookHandler.lastPayloadWasNull, 'handler told there was no JSON');
    }

    @IsTest
    static void lastSegmentParsesTheSourceFromTheUri() {
        Assert.areEqual('github', WebhookReceiver.lastSegment('/webhooks/v1/github'), 'plain');
        Assert.areEqual('github', WebhookReceiver.lastSegment('/webhooks/v1/github/'), 'trailing slash');
        Assert.isNull(WebhookReceiver.lastSegment(null), 'null');
    }
}
