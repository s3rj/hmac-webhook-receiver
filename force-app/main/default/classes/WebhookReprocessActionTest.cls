@IsTest
private class WebhookReprocessActionTest {
    private static Webhook_Event__c event(String type) {
        Webhook_Event__c event = new Webhook_Event__c(
            Source__c = 'Demo',
            Event_Type__c = type,
            External_Event_Id__c = 'Demo:' + type + ':' + Crypto.getRandomInteger(),
            Status__c = 'Received',
            Received_At__c = System.now(),
            Payload__c = '{}',
            Attempts__c = 0
        );
        insert event;
        return event;
    }

    private static WebhookReprocessAction.Request request(Id eventId) {
        WebhookReprocessAction.Request request = new WebhookReprocessAction.Request();
        request.eventId = eventId;
        return request;
    }

    @IsTest
    static void rerunsFailedEventsAndReportsTheRest() {
        WebhookDispatcher.handlerOverrides = new Map<String, WebhookDispatcher.HandlerConfig>{
            'demo|ping' => new WebhookDispatcher.HandlerConfig('RecordingWebhookHandler', false)
        };
        RecordingWebhookHandler.explode = true;
        Webhook_Event__c failed = event('ping');
        WebhookDispatcher.dispatch(failed);
        RecordingWebhookHandler.explode = false;
        Webhook_Event__c done = event('ping');
        WebhookDispatcher.dispatch(done);
        Webhook_Event__c ignored = event('unknown.type');
        WebhookDispatcher.dispatch(ignored);

        List<WebhookReprocessAction.Result> results = WebhookReprocessAction.reprocess(new List<WebhookReprocessAction.Request>{
            request(failed.Id), request(done.Id), request(ignored.Id), request(UserInfo.getUserId())
        });

        Assert.areEqual(4, results.size(), 'one result per request');
        Assert.areEqual('Processed', results[0].outcome, 'failed event re-run after the fix');
        Assert.areEqual('Skipped (Processed)', results[1].outcome, 'processed event left alone');
        Assert.areEqual('Ignored', results[2].outcome, 'still no handler for that type');
        Assert.areEqual('Skipped (not found)', results[3].outcome, 'unknown id reported');
        Assert.areEqual('Processed', [SELECT Status__c FROM Webhook_Event__c WHERE Id = :failed.Id].Status__c, 'status updated');
        Assert.areEqual(3, RecordingWebhookHandler.handled.size(), 'handler ran for the first dispatch of both, then the re-run');
    }
}
